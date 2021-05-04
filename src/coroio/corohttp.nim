import tables
import strutils
import uri
import times
import coroio
import net, httpcore
import nativesockets
import parseutils

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

proc parseRequest*(req: var Request): bool =
  req.client.getFd().setBlocking(false)

  let firstLine = req.client.recvLine().split(' ')
  parseUri(firstLine[1], req.url)

  req.headers = newHttpHeaders()
  while true:
    let line = req.client.recvLine()

    if line.len() == 0: break
    let (key, value) = parseHeader(line)
    req.headers[key] = value

  if req.headers.hasKey("Content-Length"):
    var contentLength = 0
    if parseSaturatedNatural(req.headers["Content-Length"], contentLength) == 0:
      req.respond(Http400, "Bad Request. Invalid Content-Length.")
      return false
    else:
      req.body = req.client.recv(contentLength)
      if req.body.len != contentLength:
        req.respond(Http400, "Bad Request. Content-Length does not match actual.")
        return false

  echo req.url
  result = true

proc handleRequest(server: CoroHttpServer, client: CoroSocket) =
  var req: Request = new(Request)
  req.client = client
  req.url = initUri()
  if parseRequest(req):
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
