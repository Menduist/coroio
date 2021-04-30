# This is just an example to get you started. You may wish to put all of your
# tests into a single file, or separate them into multiple `test1`, `test2`
# etc. files (better names are recommended, just make sure the name starts with
# the letter 't').
#
# To run these tests, simply execute `nimble test`.

import unittest
import times

import coroio
test "simple coro":
  var start = now()
  initCoroio()
  launchCoro(1000) do:
    coroSleep(arg)
    coroioStop()
  coroioServe()
  check (now() - start).inMilliseconds() > 900

test "parallel coro":
  var start = now()
  initCoroio()
  launchCoro("") do:
    var firstFuture: CoFuture[string]
    futureCoro(firstFuture, (1000)) do:
      coroSleep(arg[1])
      arg[0].setValue("OK 1")
    var secondFuture: CoFuture[string]
    futureCoro(secondFuture, (1000)) do:
      coroSleep(arg[1])
      arg[0].setValue("OK 2")

    check firstFuture.waitValue() == "OK 1"
    check secondFuture.waitValue() == "OK 2"
    coroioStop()

  coroioServe()
  check (now() - start).inMilliseconds() > 900
  check (now() - start).inMilliseconds() < 1800

import coroio/corohttp
#TODO tests
import coroio/coropg
#TODO tests
