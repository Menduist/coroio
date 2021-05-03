import tables
import strutils
import uri
import times
import coroio
import net, httpcore
import nativesockets

export tables, coroio, httpcore, net

type
  Request* = ref object
    client*: CoroSocket
    reqMethod*: HttpMethod
    headers*: HttpHeaders
    url*: Uri
    body*: string
    hostname*: string

  CoroHttpServer* = ref object
    socket: CoroSocket
    handler: CoroHTTPHandler

  CoroHTTPHandler* = proc(request: Request)

proc newCoroHttpServer*(): CoroHttpServer =
  result = CoroHttpServer()

proc parseRequest*(req: var Request) =
  req.client.getFd().setBlocking(false)
  #coroRegister(req.client.getFd(), {Read})
  #coroYield()

  let firstLine = req.client.recvLine().split(' ')
  parseUri(firstLine[1], req.url)

  req.headers = newHttpHeaders()
  while true:
    let line = req.client.recvLine()

    if line.len() == 0: break
    let (key, value) = parseHeader(line)
    req.headers[key] = value

  echo req.url

proc respond*(req: Request, code: HttpCode, content: string,
              headers: HttpHeaders = nil) =
  var msg = "HTTP/1.1 " & $code & "\c\L"

  if headers != nil:
    for k, v in headers:
      msg.add(k & ": " & v & "\c\L")

  msg.add("Date: " & now().utc().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'") & "\c\L")
  msg.add("Server: orlin\c\L")

  if headers.isNil() or not headers.hasKey("Content-Length"):
    msg.add("Content-Length: ")
    # this particular way saves allocations:
    msg.addInt content.len
    msg.add "\c\L"

  msg.add "\c\L"
  msg.add(content)
  req.client.send(msg)

proc handleRequest(server: CoroHttpServer, client: CoroSocket) =
  var req: Request = new(Request)
  req.client = client
  req.url = initUri()
  parseRequest(req)
  server.handler(req)
  req.client.close()

proc startServing(server: CoroHttpServer) =
  var client: CoroSocket
  coroRegister(server.socket.getFd(), {Read})

  while true:
    coroYield()
    var sock: CoroSocket
    server.socket.accept(sock)
    launchCoro((server, sock)) do:
      handleRequest(arg[0], arg[1])

proc listen*(server: CoroHttpServer, handler: CoroHTTPHandler, port: Port) =
  server.socket = newCoroSocket()
  server.socket.setSockOpt(OptReuseAddr, true)
  server.socket.bindAddr(port)
  server.handler = handler
  server.socket.listen()

  discard newCoro(server, proc (serv: CoroHttpServer) =
    startServing(serv)
  )
