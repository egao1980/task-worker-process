(defsystem "task-worker-process"
  :version "0.1.0"
  :description "Run task-protocol queue jobs each in its own child Lisp process with its own heap size"
  :author "egao1980"
  :license "MIT"
  :depends-on ()
  :serial t
  :pathname "src"
  :components ((:file "package"))
  :in-order-to ((test-op (test-op "task-worker-process/tests"))))

(defsystem "task-worker-process/tests"
  :depends-on ("task-worker-process" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "smoke-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
