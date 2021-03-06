import std/macros
import std/strutils

type
  Json* = distinct string   ## Serialized JSON.

  JasonObject = concept j
    for v in fields(j):
      jason(v) is Json

  JasonArray = concept j
    for v in j:
      jason(v) is Json

  Jasonable* = concept j   ## It should be serializable to JSON.
    jason(j) is Json

proc add(js: var Json; s: Json) {.borrow.}
proc `&`(js: Json; s: Json): Json {.borrow.}

proc join(a: openArray[Json]; sep = Json""): Json =
  for index, item in a:
    if index != 0:
      result.add sep
    result.add item

proc json(node: NimNode): NimNode =
  ## Convenience for Json(...) in macros.
  result = newCall(ident"Json", node)

proc json(node: string): NimNode =
  ## Convenience for Json("[]") in macros.
  result = json newLit(node)

func jason*(node: NimNode): NimNode =
  ## Convenience for jason(...) in macros.
  result = newCall(ident"jason", node)

macro jason*(js: Json): Json =
  ## Idempotent Json handler.
  result = js

macro jason*(s: string): Json =
  ## Escapes a string to form "JSON".
  let escapist = bindSym "escape"
  result = json newCall(escapist, s)

macro jason*(b: bool): Json =
  ## Produce a JSON boolean, either `true` or `false`.
  var cond = nnkElifExpr.newNimNode
  cond.add b
  cond.add json"true"

  var els = nnkElseExpr.newNimNode
  els.add json"false"

  result = nnkIfExpr.newNimNode
  result.add cond
  result.add els

func jason*(e: enum): Json =
  ## Render any `enum` type as a JSON integer, by default.
  result = Json($ord(e))

func jason*(i: SomeInteger): Json =
  ## Render any Nim integer as a JSON integer.
  result = Json($i)

func jason*(f: SomeFloat): Json =
  ## Render any Nim float as a JSON number.
  result = Json($f)

proc composeWithComma(parent: NimNode; js: NimNode): NimNode =
  # whether we need to add a comma before the next element
  let adder = bindSym "add"
  var comma = gensym(nskVar, "comma")
  parent.add newVarStmt(comma, ident"false")         # var comma = false

  var cond = nnkElifExpr.newNimNode
  cond.add comma                                     # if comma:
  cond.add adder.newCall(js, json",")                # js.add ","

  var toggle = nnkElseExpr.newNimNode                # else:
  toggle.add newAssignment(comma, ident"true")       # comma = true

  var sep = nnkIfExpr.newNimNode
  sep.add cond                                       # if comma: js.add ","
  sep.add toggle                                     # else: comma = true

  sep

macro jason*(a: JasonArray): Json =
  ## Render an iterable that isn't a named-tuple or object as a JSON array.
  let adder = bindSym "add"
  result = newStmtList()

  var js = gensym(nskVar, "js")
  result.add newVarStmt(js, json"[")          # the leading [

  # make a loop over the items in the iterable
  let loop = block:
    var value = gensym(nskForVar, "value")    # make loop var

    var body = nnkStmtList.newNimNode         # make body of a loop
    body.add composeWithComma(result, js)     # maybe add a separator
    body.add adder.newCall(js, value.jason)   # add the json for value

    var loop = nnkForStmt.newNimNode          # for loop
    loop.add value                            # add loop var
    loop.add a                                # add any iterable
    loop.add body                             # add loop body

    loop

  result.add loop                             # add the loop
  result.add adder.newCall(js, json"]")       # add the trailing ]

  # the last statement in the statement list is the json
  result.add js

proc jasonCurly(o: NimNode): NimNode =
  let adder = bindSym "add"
  result = newStmtList()

  var js = gensym(nskVar, "js")
  result.add newVarStmt(js, json"{")

  # make a loop over the items in the iterable
  let loop = block:
    var key = gensym(nskForVar, "key")             # loop var for key
    var val = gensym(nskForVar, "val")             # loop var for val

    var body = nnkStmtList.newNimNode              # make body of a loop
    body.add composeWithComma(result, js)          # maybe add a separator
    body.add adder.newCall(js, key.jason)          # "somekey" (json)
    body.add adder.newCall(js, json":")            # : (json)
    body.add adder.newCall(js, val.jason)          # someval (json)

    var loop = nnkForStmt.newNimNode               # make for loop
    loop.add key                                   # add key to the loop
    loop.add val                                   # add val to the loop
    loop.add newCall(ident"fieldPairs", o)         # object fieldPairs
    loop.add body                                  # loop body

    loop

  result.add loop                                  # add the loop
  result.add adder.newCall(js, json"}")            # add the trailing ]

  # the last statement in the statement list is the json
  result.add js

macro jason*(o: JasonObject): Json =
  ## Render an anonymous Nim tuple as a JSON array; objects and named
  ## tuples become JSON objects.
  let
    joiner = bindSym "join"
    ander = bindSym "&"
    typ = o.getTypeInst
  if typ.kind != nnkTupleConstr:
    # use our object construction code for named tuples, objects
    result = jasonCurly(o)
  else:
    # it is a (34, "hello")-style anonymous tuple construction
    result = newStmtList()
    # first, stash the tuple temporarily
    let temp = gensym(nskLet, "temp")
    result.add newLetStmt(temp, o)

    # arr will hold a list of strings we'll concatenate at the end
    var arr = newStmtList()
    # this is the left-bracket of the json array syntax, `[ ... ]`
    arr.add json"["
    # a nim array will serve as input to the join()
    var inf = newNimNode(nnkBracket)
    for index, sym in pairs(typ):
      # create an index expression for the temporary tuple, `:tmp[n]`
      var exp = newNimNode(nnkBracketExpr)
      # the :tmp in :tmp[3]
      exp.add temp
      # the 3 in :tmp[3]
      exp.add index.newLit # token[#] = token[#+1]
      # the jason() in jason(:tmp[3])
      inf.add exp.jason
    # now join the array with commas
    arr.add newCall(joiner, inf, json",")
    # and add the trailing "]"
    arr.add json"]"

    # now fold the array with &
    result.add nestList(ander, arr)

# i want this to be jason(o: ref Jasonable)
func jason*(o: ref): Json =
  ## Render a Nim `ref` as either `null` or the value to which it refers.
  if o.isNil:
    result = Json"null"
  else:
    result = jason o[]

func `$`*(j: Json): string =
  ## Convenience for Json.
  result = j.string
