import sysnimd

sysnimd.register Service, "test.service":
  [Unit]
  Wants = toHashSet [uname"unexisted.service"]
  [Service]
  ExecStart = proc (udata: pointer) {.async.} =
    echo "start test.service..."
    await sleepAsync(1000)
    echo "done test.service"

  [Install]
  RequiredBy = toHashSet [uname"default.target"]

sysnimd.register Service, "parallel.service":
  [Service]
  ExecStart = proc (udata: pointer) {.async.} =
    echo "start parallel.service..."
    await sleepAsync(1000)
    echo "done parallel.service"

  [Install]
  RequiredBy = toHashSet [uname"default.target"]

sysnimd.register Service, "post.service":
  [Unit]
  After = toHashSet [uname"test.service"]
  [Service]
  ExecStart = proc (udata: pointer) {.async.} =
    echo "start post.service..."
    await sleepAsync(100)
    echo "done post.service"

  [Install]
  RequiredBy = toHashSet [uname"default.target"]

sysnimd.register Service, "pre.service":
  [Unit]
  Before = toHashSet [uname"test.service"]
  [Service]
  ExecStart = proc (udata: pointer) {.async.} =
    echo "start pre.service..."
    await sleepAsync(100)
    echo "done pre.service"

  [Install]
  RequiredBy = toHashSet [uname"default.target"]

sysnimd.register Service, "disabled.service":
  [Service]
  ExecStart = proc (udata: pointer) {.async.} =
    raise newException(CatchableError, "The Unit has not disabled!")

  [Install]
  RequiredBy = toHashSet [uname"default.target"]

sysnimd.register Service, "on-release.service":
  [Service]
  ExecStart = proc (udata: pointer) {.async.} =
    echo "EXEC: on-release"
  [Install]
  RequiredBy = toHashSet [uname"release.target"]

sysnimd.register Service, "on-debug.service":
  [Service]
  ExecStart = proc (udata: pointer) {.async.} =
    echo "EXEC: on-debug"
  [Install]
  RequiredBy = toHashSet [uname"debug.target"]

sysnimd.disable "disabled.service"
sysnimd.disable "unexisted.service"

waitFor sysnimd.start()