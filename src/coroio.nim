import net, selectors, greenlet, nativesockets
import uri
import httpcore
import strutils

export selectors, greenlet

type
  CoScheluder = object
    selector: Selector[ptr Greenlet]
    coroutines: seq[ptr Greenlet]
    run: bool

  CoFuture*[T] = object
    value: T
    hasValue: bool
    parent: ptr Greenlet

var sched: CoScheluder

proc mswitchTo*(green: ptr Greenlet) =
  var frame = getFrameState()
  green.switchTo()
  setFrameState(frame)

proc mswitchTo*(green: ptr Greenlet, arg: pointer): pointer =
  var frame = getFrameState()
  result = green.switchTo(arg)
  setFrameState(frame)


proc coroSleep*(timeout: int) =
  sched.selector.registerTimer(timeout, true, currentGreenlet())
  rootGreenlet().mswitchTo()

proc coroRegister*(fd: int | SocketHandle; events: set[Event]) =
  sched.selector.registerHandle(fd, events, currentGreenlet())

proc coroUnregister*(fd: int | SocketHandle) =
  sched.selector.unregister(fd)

proc coroYield*() =
  rootGreenlet().mswitchTo()

proc init*[T](co: var CoFuture[T]) =
  co.hasValue = false
  co.parent = currentGreenlet()
  sched.selector.registerTimer(1, true, co.parent) #TODO a real scheduler would be a lot better

proc setValue*[T](co: ptr CoFuture[T], val: T) =
  co.value = val
  co.hasValue = true
  sched.selector.registerTimer(1, true, co.parent) #TODO a real scheduler would be a lot better

proc waitValue*[T](co: var CoFuture[T]): T =
  while not co.hasValue:
    coroYield()
  result = co.value

proc newCoro*[T](parm: T, start_func: proc (arg: T)): ptr Greenlet =
  var tup = (start_func, parm)
  result = newGreenlet(proc (arg: pointer): pointer =
    var t: ptr tuple[pro: proc (arg: T), arg: T] = cast[ptr tuple[pro: proc (arg: T), arg: T]](arg)
    t[0](t[1])
    return nil
  )
  sched.coroutines.add(result)
  #TODO empty coroutines
  discard result.mswitchTo(addr tup)

template launchCoro*(a, b: untyped): untyped =
  discard newCoro(a, proc (arg{.inject.}: type(a)) =
    b
  )

template futureCoro*(future, args, body: untyped): untyped =
  future.init()
  launchCoro((addr future, args), body)

proc initCoroio*() =
  sched.selector = newSelector[ptr Greenlet]()

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
