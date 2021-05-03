# coroio

A nim coroutine library made for IO-intensive projects

Currently supports sockets, http server, postgres pool & futures


## Todo

- [X] Simple socket implementation
- [X] Simple scheduler
- [X] Pooled postgres
- [ ] Complete http server
- [ ] Multithreading
- [ ] Multithreaded scheduler
- [ ] Better optimization
- [ ] Exceptions & cancellation
## Why and how

Coroutines are great because you can yield from a "deep" function, without having to use async on every function of the call stack.
```nim
func deepFunction() =
  while notReady(): coroYield() #Will yield properly
  result = getResult()

launchCoro("") do:
  deepFunction()
```
This way, the asynchronous code can be truly transparent to the programmer (if the library he uses handle coroutines properly). Besides, this requires a lot less compiler trickery than async for instance.

Downsides: more ram usage (a entire stack has to be allocated for each running coroutine), and requires per architecture code to switch between coroutines.

The API of this library is very experimental at this point. Every parameter to a coroutine must pass through `launchCoro(HERE)`/`futureCoro(xx, HERE)`. You can use a tuple to pass multiple values.

Some code has been stolen & adapted from [greenlet](https://github.com/treeform/greenlet) and asyncpgpool
## Examples

Simple coroutines
```nim
import coroio
initCoroio()
launchCoro(1000) do:
  echo "A"
  coroSleep(arg)
  echo "C"
launchCoro("B") do:
  echo arg
coroioServe()
#Output: A B C
```

Basic http server
```nim
import coroio
import coroio/corohttp

proc handleRequest(req: Request) =
  req.respond(Http200, "OK")

initCoroio()
newCoroHttpServer().listen(handleRequest, Port(80))
coroioServe()
```

CoFuture usage (to be improved)
```nim
launchCoro("") do:
  let start = now()
  var firstFuture: CoFuture[string]
  futureCoro(firstFuture, 1000) do:
    coroSleep(arg[1])
    arg[0].setValue("OK 1")
  var secondFuture: CoFuture[string]
  futureCoro(secondFuture, 500) do:
    coroSleep(arg[1])
    arg[0].setValue("OK 2")

  assert firstFuture.waitValue() == "OK 1"
  assert secondFuture.waitValue() == "OK 2"
  echo now() - start #1000 ms instead of 1500

coroioServe()
```
