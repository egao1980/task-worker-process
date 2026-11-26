(defsystem "task-worker-process"
  :version "0.1.0"
  :description "Run task-protocol queue jobs each in its own child Lisp process with its own heap size"
  :author "egao1980"
  :license "MIT"
  ;; bordeaux-threads: job threads and the claim loop (already in the graph
  ;; through task-backend-sql / sql-protocol and Rove). babel: through
  ;; process-backend-uiop; the channel's UTF-8 byte frames.
  :depends-on ((:version "task-protocol" "0.3.0")
               (:version "process-protocol" "0.4.1")
               "process-backend-uiop"
               "bordeaux-threads"
               "task-worker-process/child")
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "conditions")
               (:file "registry")
               (:file "supervisor"))
  :in-order-to ((test-op (test-op "task-worker-process/tests"))))

(defsystem "task-worker-process/child"
  :version "0.1.0"
  :description "The child side of task-worker-process: channel frames and the child entry point"
  :author "egao1980"
  :license "MIT"
  :depends-on ("babel")
  :serial t
  :pathname "src/child"
  :components ((:file "package")
               (:file "channel")
               (:file "main")))

(defsystem "task-worker-process/tests"
  ;; The fixture handler system (tests/fixtures/) is loaded by the children
  ;; only, through the inherited source registry: no dependency here.
  :depends-on ("task-worker-process" "rove" "bordeaux-threads"
               "task-backend-sql" "sql-backend-sqlite3")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "support")
               (:file "channel-test")
               (:file "registry-test")
               (:file "config-test")
               (:file "outcome-test")
               (:file "run-test")
               (:file "failure-test")
               (:file "cancel-test")
               (:file "lease-test")
               (:file "concurrency-test")
               (:file "shutdown-test")
               (:file "sql-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
