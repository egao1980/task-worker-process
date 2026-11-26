# task-worker-process

A supervisor that runs [`task-protocol`](https://github.com/egao1980/task-protocol)
job-queue jobs (0.3.0 queue, any backend), each in its own child Lisp process
with its own heap size. One job that exhausts its heap, crashes or hangs fails
that job only; the supervisor and the other jobs keep running.

Motivating consumer: a service running a few multi-GB-heap batch jobs, where
one job exhausting its heap must not take down the others.

```lisp
(asdf:load-system "task-worker-process")
```

Status: skeleton. The 0.1.0 contract is in progress.

## License

MIT — see [LICENSE](LICENSE).
