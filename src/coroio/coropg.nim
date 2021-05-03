import json, times
include db_postgres

import coroio

type
  ## db pool
  AsyncPool* = ref object
    conns*: seq[DbConn]
    busy*: seq[bool]

  ## Exception to catch on errors
  PGError* = object of IOError

var globAsyncPool: AsyncPool

proc newCoropgPool*(
    connection,
    user,
    password,
    database: string,
    num: int
  ): AsyncPool =
  ## Create a new async pool of num connections.
  result = AsyncPool()
  result.busy = newSeq[bool](num)
  for i in 0..<num:
    let conn = open(connection, user, password, database)
    assert conn.status == CONNECTION_OK
    discard conn.pqsetnonblocking(1)
    result.conns.add(conn)
  globAsyncPool = result

proc getFreeConnIdx*(pool: AsyncPool): int =
  ## Wait for a free connection and return it.
  while true:
    for conIdx in 0..<pool.conns.len:
      if not pool.busy[conIdx]:
        pool.busy[conIdx] = true
        return conIdx
    coroSleep(10)

proc returnConn*(pool: AsyncPool, conIdx: int) =
  ## Make the connection as free after using it and getting results.
  pool.busy[conIdx] = false

proc checkError(db: DbConn) =
  ## Raises a DbError exception.
  var message = pqErrorMessage(db)
  if message.len > 0:
    raise newException(PGError, $message)


# ==================================================
proc coropgGetAllRows(db: DbConn, query: SqlQuery, args: varargs[string, `$`]): seq[Row] =
  assert db.status == CONNECTION_OK
  let success = pqsendQuery(db, dbFormat(query, args))
  coroRegister(pqSocket(db).int, {Read})
  if success != 1: dbError(db) # never seen to fail when async
  while true:
    let success = pqconsumeInput(db)
    if success != 1: dbError(db) # never seen to fail when async
    if pqisBusy(db) == 1:
      coroYield()
      continue
    var pqresult = pqgetResult(db)
    if pqresult == nil:
      # Check if its a real error or just end of results
      db.checkError()
      break
    var cols = pqnfields(pqresult)
    var row = newRow(cols)
    for i in 0'i32..pqNtuples(pqresult)-1:
      setRow(pqresult, row, i, cols)
      result.add row
    pqclear(pqresult)
  coroUnregister(pqSocket(db).int)

proc coropgGetAllRows*(pool:AsyncPool,
                          sqlString:SqlQuery,
                          args:seq[string]): seq[Row] =
    let conIdx = pool.getFreeConnIdx()
    result = coropgGetAllRows(pool.conns[conIdx], sqlString, args)
    pool.returnConn(conIdx)

proc coropgGetAllRows*(sqlString:SqlQuery, args:varargs[string, `$`]): seq[Row] =
  result = coropgGetAllRows(globAsyncPool, sqlString, @args)

proc coropgGetRow(db: DbConn, query: SqlQuery, args: varargs[string, `$`]): Row =
  assert db.status == CONNECTION_OK
  let success = pqsendQuery(db, dbFormat(query, @args))
  coroRegister(pqSocket(db).int, {Read})
  if success != 1: dbError(db) # never seen to fail when async
  while true:
    let success = pqconsumeInput(db)
    if success != 1: dbError(db) # never seen to fail when async
    if pqisBusy(db) == 1:
      coroYield()
      continue
    var pqresult = pqgetResult(db)
    if pqresult == nil:
      # Check if its a real error or just end of results
      db.checkError()
      break
    var cols = pqnfields(pqresult)
    var row = newRow(cols)
    setRow(pqresult, row, 0, cols)
    result.add(row)
    pqclear(pqresult)
  coroUnregister(pqSocket(db).int)


proc coropgGetRow*(pool:AsyncPool,
                        sqlString:SqlQuery,
                        args:varargs[string, `$`]): Row =
  let conIdx = pool.getFreeConnIdx()
  result = coropgGetRow(pool.conns[conIdx], sqlString, @args)
  pool.returnConn(conIdx)

proc coropgGetRow*(sqlString:SqlQuery,
                        args:varargs[string, `$`]): Row =
  result = coropgGetRow(globAsyncPool, sqlString, @args)

proc coropgExec(db: DbConn, query: SqlQuery, args: varargs[string, `$`]) =
  assert db.status == CONNECTION_OK
  let success = pqsendQuery(db, dbFormat(query, @args))
  coroRegister(pqSocket(db).int, {Read})
  if success != 1: dbError(db)
  while true:
    let success = pqconsumeInput(db)
    if success != 1: dbError(db) # never seen to fail when async
    if pqisBusy(db) == 1:
      coroYield()
      continue
    var pqresult = pqgetResult(db)
    if pqresult == nil:
      # Check if its a real error or just end of results
      db.checkError()
      break
    pqclear(pqresult)
  coroUnregister(pqSocket(db).int)

proc coropgExec*(pool:AsyncPool,
                  sqlString:SqlQuery,
                  args:varargs[string, `$`]) =
  let conIdx = pool.getFreeConnIdx()
  coropgExec(pool.conns[conIdx], sqlString, @args)
  pool.returnConn(conIdx)

proc coropgExec*(sqlString:SqlQuery, args:varargs[string, `$`]) =
  coropgExec(globAsyncPool, sqlString, @args)
