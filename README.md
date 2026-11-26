# task-worker-process

A supervisor that runs [`task-protocol`](https://github.com/egao1980/task-protocol)
job-queue jobs (0.3 queue, any backend), each in its own child Lisp process
with its own heap size. A job that exhausts its heap, crashes or hangs fails
that job only; the supervisor and the other jobs keep running.

Motivating consumer: a service running a few multi-GB-heap batch jobs, where
one job exhausting its heap must not take down the others.

```lisp
(asdf:load-system "task-worker-process")

(let* ((queue (stack-task:make-in-memory-job-queue
               :resource-classes '((:large 1) (:small 4))))
       (registry (stack-task-worker:make-handler-registry)))
  (stack-task-worker:define-job-handler registry :render "my-batch:render"
                                        :systems '("my-batch") :timeout 3600)
  (let ((sup (stack-task-worker:make-process-supervisor
              queue registry
              :heap-sizes '((:large . 8192) (:small . 1024)))))
    (stack-task-worker:start-supervisor sup)
    (stack-task:submit-job queue :render :payload '(:input "a.dat")
                                         :resource-class :large)
    ;; …
    (stack-task-worker:stop-supervisor sup :grace 60)))
```

The handler lives in `my-batch` and is loaded in the child only:

```lisp
(defun render (payload &key report-progress cancel-requested-p)
  (funcall report-progress :phase "load" :fraction 0)
  (unless (funcall cancel-requested-p) …)
  (list :output "a.out"))
```

## 0.1.0 (contract)

Status: implemented (team-solve: 38 tests). The spec is the file headers (`src/supervisor.lisp`,
`src/registry.lisp`, `src/child/channel.lisp`, `src/child/main.lisp`); the tests in `tests/` grade them.

Dependencies: `task-protocol` 0.3.0, `process-protocol` 0.4.1 +
`process-backend-uiop` (launch / wait / kill, process groups),
`bordeaux-threads` (job threads, already in the graph through
`task-backend-sql` and Rove), `babel` (UTF-8 frames, already in the graph
through `process-backend-uiop`). Tests add `task-backend-sql` 0.2.0 +
`sql-backend-sqlite3` and Rove.

| Piece | API |
|-------|-----|
| Registry | `make-handler-registry` · `define-job-handler registry kind handler &key systems timeout` · `find-job-handler` (`:errorp`) · `remove-job-handler` · `list-job-handlers` · `job-handler-kinds` · readers `job-handler-kind/-function/-systems/-timeout` |
| Supervisor | `make-process-supervisor queue registry &key worker-id lease-seconds heartbeat-interval poll-interval claim-interval heap-sizes default-heap-mb cancel-grace lisp-command source-registry work-directory keep-work-directories on-child-failure` · `run-next-job` · `start-supervisor` · `stop-supervisor &key grace killed wait` · `supervisor-state` · `supervisor-running-jobs` · `supervisor-child-pid` · `job-heap-mb` · `default-lisp-command` |
| Child side (`task-worker-process/child`) | `child-main` · `frame-string` · `write-frame` · `read-frames` · `channel-error` · job directory names `+request-file+` `+channel-file+` `+cancel-file+` `+log-file+` `+boot-file+` |
| Conditions | `worker-error` → `worker-configuration-error` (`use-value`) → `invalid-job-handler` (`use-value`); `unknown-job-kind` (`use-value`); `child-failure` (`continue` = fail the job, `retry-child`, `use-value` = complete with a value) |

Semantics in short:

- **Handlers.** A job kind maps to a package-qualified function name
  (`"pkg:name"`, read in the child after its systems load) and the systems
  the child loads. A handler is `(payload &key report-progress
  cancel-requested-p) → result`. The parent never loads handler code.
- **One child per job.** Each claimed job gets a fresh job directory and a
  fresh child Lisp. The default command is this image's SBCL runtime and
  core with `--dynamic-space-size <MB>MB`, MB from the job's resource class
  (`:heap-sizes`, else `:default-heap-mb`). The child inherits the parent's
  ASDF source registry and output translations (under `cl-repo test` /
  `cl-repo run`: the project registry). `:lisp-command` replaces the
  command (another Lisp, a wrapper, a container).
- **Channel: a file, not stdout.** The child writes byte-length-framed
  s-expressions (progress, then one result or error) to `channel` in the job
  directory; its stdout and stderr go to `child.log`. Handler output cannot
  corrupt the frames, the parent reads them in the poll loop it already runs
  (no reader thread, no pipe that blocks the child), and frames written
  before a crash stay on disk. Values cross as standard-syntax readable
  forms: the queue's serializable values minus hash tables.
- **Leases, progress, outcome.** While the child runs the parent heartbeats
  the lease, relays progress frames into `report-job-progress` in order,
  and finally completes, fails or acknowledges the job. A dead child
  (heap exhausted, crash, non-zero exit, signal, no result) fails the job
  with `"child failure (<reason>): <detail>"`; the supervisor keeps running.
- **Timeout and cancel.** A per-kind timeout kills the child (`timeout`).
  A cancel request creates `cancel` in the job directory (the handler's
  `cancel-requested-p`); after `:cancel-grace` seconds the child is killed;
  the job is acknowledged `:canceled`. Kills reach the child's process group.
- **Concurrency** is bounded by the queue's resource classes, not by the
  supervisor: the claim loop claims while the queue admits.
- **Shutdown.** `stop-supervisor` stops claiming, gives running children
  `:grace` seconds, then kills the rest: their jobs fail (`shutdown`) or,
  with `:killed :release`, are left to lease expiry and re-queued.

| File | Status |
|------|--------|
| `src/package.lisp`, `src/conditions.lisp` | given |
| `src/registry.lisp` (classes) / (operations) | given / contract |
| `src/supervisor.lisp` (class) / (operations) | given / contract |
| `src/child/package.lisp` (names, `channel-error`) | given |
| `src/child/channel.lisp`, `src/child/main.lisp` | contract |
| `tests/fixtures/` (test-only handler system, loaded by the children) | given |
| `tests/support.lisp` | given (helpers) |
| `tests/*-test.lisp` | contract |

Tests start real child SBCLs (256–512 MB heaps) through the default
command; run them with `cl-repo test`. Unix only (they use `/bin/sh` and
`kill`). Not covered by 0.1.0: Windows, non-SBCL children (the default
command is SBCL only), warm child pools.

## License

MIT — see [LICENSE](LICENSE).
