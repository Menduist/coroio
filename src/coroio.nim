import std/importutils
import net
import selectors, coroio/greenlet, nativesockets
import httpcore
import os
import strutils
import times

export selectors

type
  Coroutine* = ref object
    greenlet: ptr Greenlet
    running: bool
    id: int
    timeStart: DateTime

  CoScheluder = object
    selector: Selector[Coroutine]
    coroutines: seq[Coroutine]
    run: bool
    totalId: int

  CoFuture*[T] = object
    value: T
    hasValue: bool
    parent: Coroutine

  CoroSocket* {.borrow: `.`.} = distinct Socket
privateAccess(Socket)

var sched: CoScheluder
var currentCoroutine: Coroutine
var rootCoroutine: Coroutine

proc mswitchTo*(coro: Coroutine, arg: pointer): pointer =
  let timeEnd = now()
  if currentCoroutine != rootCoroutine and (timeEnd - currentCoroutine.timeStart).inMilliseconds() > 5:
    echo "Long running coroutine! (", (timeEnd - currentCoroutine.timeStart).inMilliseconds(), " ms)"
    echo getStackTrace()
  var frame = getFrameState()
  currentCoroutine = coro
  coro.running = true
  result = coro.greenlet.switchTo(arg)
  currentCoroutine.timeStart = now()
  setFrameState(frame)

proc mswitchTo*(coro: Coroutine) =
  discard coro.mswitchTo(nil)

proc coroRegister*(fd: int | SocketHandle; events: set[Event]) =
  sched.selector.registerHandle(fd, events, currentCoroutine)

proc coroUnregister*(fd: int | SocketHandle) =
  sched.selector.unregister(fd)

proc coroYield*(stopRunning = true) =
  currentCoroutine.running = not stopRunning
  rootCoroutine.mswitchTo()

proc coroSleep*(timeout: int) =
  let start = now()
  sched.selector.registerTimer(timeout, true, currentCoroutine)
  while (now() - start).inMilliseconds() < timeout - 2:
    coroYield()

proc getFd*(socket: CoroSocket): SocketHandle {.borrow.}

proc send*(socket: CoroSocket, data: pointer, size: int): int {.tags: [WriteIOEffect], borrow.}

proc close*(socket: CoroSocket; flags = {SafeDisconn}) {.borrow.}

proc setSockOpt*(socket: CoroSocket, opt: SOBool, value: bool, level = SOL_SOCKET) {.tags: [WriteIOEffect]} =
  #Borrowing doesn't work here?
  ((Socket)socket).setSockOpt(opt, value, level)

proc listen*(socket: CoroSocket, backlog = SOMAXCONN) {.tags: [ReadIOEffect], borrow.}

proc bindAddr*(socket: CoroSocket, port = Port(0), address = "") {.tags: [ReadIOEffect].} =
  ((Socket)socket).bindAddr(port, address)

proc toCoroSocket*(socket: Socket): CoroSocket =
  # Don't use a converter to avoir mistakes
  socket.getFd().setBlocking(false)
  result = CoroSocket(socket)


proc accept*(server: CoroSocket, client: var owned(CoroSocket),
             flags = {SocketFlag.SafeDisconn},
             inheritable = defined(nimInheritHandles))
            {.tags: [ReadIOEffect].} =
  var tmpSocket: Socket
  ((Socket)server).accept(tmpSocket, flags, inheritable)
  client = tmpSocket.toCoroSocket()

proc send*(socket: CoroSocket, data: string,
           flags = {SocketFlag.SafeDisconn}) {.tags: [WriteIOEffect], borrow.}

proc newCoroSocket*(): CoroSocket =
  result = CoroSocket(newSocket())
  result.getFd().setBlocking(false)

proc readInto(buf: pointer, size: int, socket: CoroSocket, flags: set[SocketFlag]): int =
  let sock = Socket(socket)
  while true:
    let res = sock.fd.recv(buf, size.cint, flags.toOSFlags())
    if res < 0:
      let lastError = osLastError()
      if lastError.int32 != EINTR and lastError.int32 != EWOULDBLOCK and
        lastError.int32 != EAGAIN:
        if flags.isDisconnectionError(lastError):
          return 0
        else:
          raise newException(OSError, osErrorMsg(lastError))
      else:
        coroRegister(sock.fd, {Read})
        coroYield()
        coroUnregister(sock.fd)
        continue #Retry later
    else:
      return res
  

proc readIntoBuf(socket: CoroSocket, flags = {SocketFlag.SafeDisconn}): int =
  let sock = Socket(socket)
  result = readInto(addr sock.buffer[0], BufferSize, socket, flags)
  sock.currPos = 0
  sock.bufLen = result

proc recvInto*(socket: CoroSocket, resString: var string, size: int, flags = {SocketFlag.SafeDisconn}) =
  let sock = (Socket)socket
  if sock.isBuffered:
    var read = 0

    while read < size:
      if sock.currPos >= sock.bufLen:
        let res = socket.readIntoBuf(flags)
        if res == 0:
          resString = ""
          return
      let chunk = min(sock.bufLen-sock.currPos, size-read)
      copyMem(addr(resString[read]), addr(sock.buffer[sock.currPos]), chunk)
      read.inc(chunk)
      sock.currPos.inc(chunk)
    resString.setLen(read)
  else:
    #TODO
    discard

proc recv*(socket: CoroSocket, size: int, flags = {SocketFlag.SafeDisconn}): string =
  result = newString(size)
  socket.recvInto(result, size, flags)

proc recvLineInto*(socket: CoroSocket, resString: var string, flags = {SocketFlag.SafeDisconn}) =
  let sock = (Socket)socket
  if sock.isBuffered:
    var lastR = false
    while true:
      if sock.currPos >= sock.bufLen:
        let res = socket.readIntoBuf(flags)
        if res == 0:
          resString = ""
          return

      case sock.buffer[sock.currPos]
      of '\r':
        lastR = true
      of '\L':
        sock.currPos.inc()
        return
      else:
        if lastR:
          sock.currPos.inc()
          return
        else:
          resString.add sock.buffer[sock.currPos]
      sock.currPos.inc()
  else:
    #TODO
    discard

proc recvLine*(socket: CoroSocket): string =
  socket.recvLineInto(result)

proc init*[T](co: var CoFuture[T]) =
  co.hasValue = false
  co.parent = currentCoroutine

proc setValue*[T](co: ptr CoFuture[T], val: T) =
  co.value = val
  co.hasValue = true
  co.parent.running = true

proc waitValue*[T](co: var CoFuture[T]): T =
  while not co.hasValue:
    coroYield()
  result = co.value

proc newCoro*[T](parm: T, start_func: proc (arg: T)): Coroutine =
  result = Coroutine()
  result.greenlet = newGreenlet(proc (arg: pointer): pointer =
    var t: ptr tuple[pro: proc (arg: T), arg: T, coro: Coroutine] = cast[ptr tuple[pro: proc (arg: T), arg: T, coro: Coroutine]](arg)
    currentCoroutine = t[2]
    currentCoroutine.timeStart = now()
    t[0](t[1])
    sched.coroutines.del(sched.coroutines.find(currentCoroutine))
    return nil
  )
  sched.coroutines.add(result)
  inc(sched.totalId)
  result.id = sched.totalId
  var tup = (start_func, parm, result)
  discard result.mswitchTo(addr tup)

template launchCoro*(a, b: untyped): untyped =
  discard newCoro(a, proc (arg{.inject.}: type(a)) =
    b
  )

template futureCoro*(future, args, body: untyped): untyped =
  future.init()
  launchCoro((addr future, args), body)

proc initCoroio*() =
  sched.selector = newSelector[Coroutine]()
  rootCoroutine = Coroutine()
  rootCoroutine.greenlet = rootGreenlet()
  rootCoroutine.timeStart = now()
  currentCoroutine = rootCoroutine

proc coroioServe*() =
  var keys: array[64, ReadyKey]
  var hasRunning: bool = false
  sched.run = true
  while sched.run:
    var eventCount = sched.selector.selectInto(if hasRunning: 0 else: 5, keys)
    for i in 0..<eventCount:
      sched.selector.getData(keys[i].fd).running = true
    hasRunning = false
    var i = 0
    while i < sched.coroutines.len():
      if sched.coroutines[i].running:
        sched.coroutines[i].mswitchTo()
      inc(i)
    for coro in sched.coroutines:
      if coro.running: hasRunning = true
  echo "Finished loop"

proc coroioStop*() =
  sched.run = false
