{.define: nimPreviewHashRef.}

import std/asyncdispatch
import std/tables
import std/sets
import std/strutils
import std/macros

export asyncdispatch, sets

type
  UnitConflictDefect* = object of CatchableError
  ResolveError* = object of CatchableError

  UnitStatus* = enum
    Unknown
    Disabled
    Failed
    Ready
    Running
    Completed

  UnitName* = object
    str: string

  UnitSection* = object
    Requires*, Wants*: HashSet[UnitName]
    # Conflicts*: seq[UnitName]
    Before*, After*: HashSet[UnitName]
  InstallSection* = object
    RequiredBy*, WantedBy*: HashSet[UnitName]

  ServiceSection* = object
    ExecStart*: proc(userdata: pointer): Future[void] {.gcsafe.}

  Unit* = ref object of RootObj
    name: UnitName
    disabled: bool
    current: Future[void]
    installed: tuple[
      Requires, Wants: HashSet[UnitName];
      After: HashSet[UnitName]
    ]
    Unit*: UnitSection
    Install*: InstallSection

  Service* = ref object of Unit
    Service: ServiceSection
  Target* = ref object of Unit
  Symlink* = ref object of Unit
    linked*: UnitName

  UnitDB* = ref object
    unitTable: Table[UnitName, Unit]

var unitDB = new UnitDB

proc `$`*(name: UnitName): string = name.str
template await*(unit: Unit) =
  if unit.current != nil:
    await unit.current

proc register*(unit: Unit) =
  if ($unit.name).isEmptyOrWhiteSpace:
    raise newException(UnitConflictDefect, "The Unit has no name.")
  if unitDB.unitTable.hasKey(unit.name):
    raise newException(UnitConflictDefect, "`" & $unit.name & "` is already exists.")
  unitDB.unitTable[unit.name] = unit
proc overwrite*(unit: Unit) =
  if ($unit.name).isEmptyOrWhiteSpace:
    raise newException(UnitConflictDefect, "The Unit has no name.")
  unitDB.unitTable[unit.name] = unit

converter resolve*(name: UnitName): Unit =
  try:
    unitDB.unitTable[name]
  except KeyError:
    raise newException(ResolveError, "ResolveError: `" & $name & "` does not exist.")

converter uname*(str: string): UnitName = UnitName(str: str)
proc uname*(unit: Unit): UnitName = unit.name

proc ln*(src: Unit, dst: Symlink) =
  dst.linked = src.name
proc ln*(src, dst: UnitName) =
  let symlink = SymLink resolve dst
  if symlink.isNil:
    raise newException(UnitConflictDefect, $dst & " does not exist/SymLink")
  symlink.linked = src

proc status*(unit: Unit): UnitStatus =
  if unit.disabled: return Disabled
  if unit.current.isNil: return Ready
  if not finished unit.current: return Running
  if failed unit.current: return Failed
  return Completed

proc disable*(unit: Unit) = unit.disabled = true
proc enable*(unit: Unit) = unit.disabled = false
proc disable*(name: UnitName) =
  try: name.resolve.disabled = true
  except ResolveError: discard
proc enable*(name: UnitName) =
  try: name.resolve.disabled = false
  except ResolveError: discard

method execute*(self: Unit): Future[void] {.base.} =
  discard

proc start*(self: Unit): Future[void] {.async.} =
  if self.status != Ready: return self.current
  proc launch(unit: Unit) =
    discard start unit

  self.current = newFuture[void]("start")
  result = self.current

  var After, Parallel: HashSet[Unit]

  for name in self.Unit.After + self.installed.After:
    After.incl resolve name
  for name in self.Unit.Requires + self.installed.Requires:
    Parallel.incl resolve name
  for name in self.Unit.Wants + self.installed.Wants:
    try: Parallel.incl resolve name
    except ResolveError: discard

  for unit in After: launch unit
  for unit in Parallel: launch unit

  for unit in After: await unit

  let selftask = execute self
  if selftask != nil: await selftask

  for unit in Parallel: await unit

  complete result

proc start*(name: UnitName): Future[void] = start resolve name

method execute*(self: Service): Future[void] =
  if self.Service.ExecStart.isNil: return
  self.Service.ExecStart(nil)

method execute*(self: Target): Future[void] =
  discard

method execute*(self: Symlink): Future[void] =
  start resolve self.linked


proc install* =
  for name, unit in unitDB.unitTable:
    for wanted in unit.Install.WantedBy:
      resolve(wanted).installed.Wants.incl unit.name
    for required in unit.Install.RequiredBy:
      resolve(required).installed.Requires.incl unit.name

    for before in unit.Unit.Before:
      resolve(before).installed.After.incl unit.name
proc start*: Future[void]  =
  install()
  start "default.target"

proc defineImpl*(UnitType, name, body: NimNode): NimNode =
  let res = genSym(nskLet, "res")
  let asgns = newStmtList()
  var currSec: NimNode
  for stmt in body:
    case stmt.kind
    of nnkBracket:
      currSec = stmt[0]
    of nnkAsgn:
      var (asgn0, asgn1) = (stmt[0], stmt[1])
      asgns.add nnkAsgn.newTree(
        nnkDotExpr.newTree(nnkDotExpr.newTree(res, currSec), asgn0),
        asgn1
      )
    else:
      discard

  result = quote do:
    let `res` = `UnitType`(
      name: `name`
    )
    `asgns`
    `res`

macro define*[T: Unit](UnitType: typedesc[T]; name: UnitName; body): T =
  defineImpl(UnitType, name, body)
macro define*[T: Unit](UnitType: typedesc[T]; name: UnitName): T =
  defineImpl(UnitType, name, newEmptyNode())

macro register*[T: Unit](UnitType: typedesc[T]; name: UnitName; body) =
  bindSym"register".newCall defineImpl(UnitType, name, body)
macro register*[T: Unit](UnitType: typedesc[T]; name: UnitName) =
  bindSym"register".newCall defineImpl(UnitType, name, newEmptyNode())

macro overwrite*[T: Unit](UnitType: typedesc[T]; name: UnitName; body) =
  bindSym"overwrite".newCall defineImpl(UnitType, name, body)
macro overwrite*[T: Unit](UnitType: typedesc[T]; name: UnitName) =
  bindSym"overwrite".newCall defineImpl(UnitType, name, newEmptyNode())

var default_target = define(SymLink, "default.target")
register default_target

register Target, "release.target"
register Target, "debug.target":
  [Unit]
  Requires = toHashSet [uname"release.target"]
  After = toHashSet [uname"release.target"]

when defined release:
  ln "release.target", "default.target"
else:
  ln "debug.target", "default.target"
