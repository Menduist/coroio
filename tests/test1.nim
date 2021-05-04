# This is just an example to get you started. You may wish to put all of your
# tests into a single file, or separate them into multiple `test1`, `test2`
# etc. files (better names are recommended, just make sure the name starts with
# the letter 't').
#
# To run these tests, simply execute `nimble test`.

import unittest
import times
import osproc
import streams

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

test "http server basic":
  initCoroio()
  let serv = newCoroHttpServer()
  serv.listen(proc (req: Request) =
    check req.url.path == "/path"
    req.respond(Http404, "Test reply")
  , Port(8080))
  var responseFuture: CoFuture[string]
  futureCoro(responseFuture, "") do:
    coroSleep(100)
    let curl = startProcess("/usr/bin/curl", args = ["--limit-rate", "1", "-s", "http://127.0.0.1:8080/path"])
    coroSleep(500)
    arg[0].setValue(curl.outputStream().readAll())
    coroioStop()
  coroioServe()
  check responseFuture.waitValue() == "Test reply"

test "http server POST":
  initCoroio()
  let serv = newCoroHttpServer()
  serv.listen(proc (req: Request) =
    check req.url.path == "/path"
    check req.body == "Test Body"
    req.respond(Http200, "Test reply")
  , Port(8081))
  launchCoro("") do:
    coroSleep(100)
    let curl = startProcess("/usr/bin/curl", args = ["-X", "POST", "-s", "http://127.0.0.1:8081/path", "-d", "Test Body"])
    coroSleep(500)
    check curl.outputStream().readAll() == "Test reply"
    coroioStop()
  coroioServe()

import coroio/coropg
#TODO tests
