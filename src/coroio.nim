import net, selectors, greenlet, nativesockets
import uri
import httpcore
import strutils

export selectors, greenlet

type
  Coroutine = ref object
    greenlet: ptr Greenlet
    running: bool

  CoScheluder = object
    selector: Selector[Coroutine]
    coroutines: seq[Coroutine]
    run: bool

  CoFuture*[T] = object
    value: T
    hasValue: bool
    parent: Coroutine

var sched: CoScheluder
var currentCoroutine: Coroutine
var rootCoroutine: Coroutine

proc mswitchTo*(coro: Coroutine, arg: pointer): pointer =
  var frame = getFrameState()
  currentCoroutine = coro
  result = coro.greenlet.switchTo(arg)
  setFrameState(frame)

proc mswitchTo*(coro: Coroutine) =
  discard coro.mswitchTo(nil)

proc coroSleep*(timeout: int) =
  sched.selector.registerTimer(timeout, true, currentCoroutine)
  rootCoroutine.mswitchTo()

proc coroRegister*(fd: int | SocketHandle; events: set[Event]) =
  sched.selector.registerHandle(fd, events, currentCoroutine)

proc coroUnregister*(fd: int | SocketHandle) =
  sched.selector.unregister(fd)

proc coroYield*() =
  rootCoroutine.mswitchTo()

proc init*[T](co: var CoFuture[T]) =
  co.hasValue = false
  co.parent = currentCoroutine
  sched.selector.registerTimer(1, true, co.parent) #TODO a real scheduler would be a lot better

proc setValue*[T](co: ptr CoFuture[T], val: T) =
  co.value = val
  co.hasValue = true
  sched.selector.registerTimer(1, true, co.parent) #TODO a real scheduler would be a lot better

proc waitValue*[T](co: var CoFuture[T]): T =
  while not co.hasValue:
    coroYield()
  result = co.value

proc newCoro*[T](parm: T, start_func: proc (arg: T)): Coroutine =
  var tup = (start_func, parm)
  result = Coroutine()
  result.greenlet = newGreenlet(proc (arg: pointer): pointer =
    var t: ptr tuple[pro: proc (arg: T), arg: T] = cast[ptr tuple[pro: proc (arg: T), arg: T]](arg)
    t[0](t[1])
    sched.coroutines.del(sched.coroutines.find(currentCoroutine))
    return nil
  )
  sched.coroutines.add(result)
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
  currentCoroutine = rootCoroutine

proc coroioServe*() =
  var keys: array[64, ReadyKey]
  sched.run = true
  while sched.run:
    var eventCount = sched.selector.selectInto(-1, keys)
    for i in 0..<eventCount:
      sched.selector.getData(keys[i].fd).mswitchTo()
  echo "Finished loop"

proc coroioStop*() =
  sched.run = false
