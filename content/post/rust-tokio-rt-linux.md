---
title: "Who dared to kill my process?"
date: 2026-04-26T16:29:11+02:00
author: Javier Alvarez
layout: post
tags:
  - Rust
  - Async Rust
  - Tokio
  - Embedded linux
  - Real-time
  - Real-time linux
  - eBPF
  - bpftrace
draft: true
---

# Introduction

What do you do when you run your program and you just see this?

```sh
$ ./target/debug/my-program
Starting application
Killed                     ./target/debug/my-blaster
```

Interestingly, the application runs fine when I enable some debug logs:

```sh
$ ./target/debug/my-program --show-logs
Starting application
Sending 0
Sending 0
Received Some(0)
Sending 1
Received Some(0)
Sending 2
Received Some(1)
Sending 3
Received Some(2)
...
```

There are a myriad of reasons that could trigger a signal to be delivered to a 
process and killing it. So my first thought is I need to understand what kind of 
signal I am getting. I can do this by using bash `$?`, which returns the exit 
status of the process. When a signal kills the process, the exit status is 
`128 + N`, where `N` is the number of the signal that killed the process.[^1]

```sh
$ echo $?
137
```

An exit status of `137` corresponds to signal `9`. On Linux, the `man` page `signals` in section `7` 
describes the standardized signal numbers and the corresponding signals.[^2] Signal `9` corresponds to
a `SIGKILL`.

A `SIGKILL` cannot be handled by a process and causes the immediate termination of the process.
But the question here is who is delivering this signal to my process? And why is it doing so?

In this post I will show you how I managed to find answers to these questions. Turns out the answers 
to the questions are quite interesting, but I believe the process of finding the answers is just as 
relevant.

But first, let me put you in context of what my application does.

# What is my program doing?

Having a strong mental model for your application, the libraries you are using, as well as the 
operating system and related relevant infrastructure helps immensely during the debugging process.

That's why here I am going to introduce my application (or rather, a minimal reproducer that stills 
shows the same problem) so that we can proceed to the debugging process.

The application code is shown below. It's a small Rust application that uses Tokio to run a couple
of async tasks in parallel. These tasks run on a single-threaded runtime which has its thread 
configuration set to use a real-time priority with a round-robin schedule policy. Both async tasks 
are simply sending each other ping-pong data using unbounded channels.

```rust
use clap::Parser;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};

#[derive(clap::Parser)]
struct Args {
    #[arg(long)]
    show_logs: bool,
}

fn configure_rt_thread() {
    thread_priority::set_thread_priority_and_policy(
        thread_priority::thread_native_id(),
        50.try_into().unwrap(),
        thread_priority::ThreadSchedulePolicy::Realtime(
            thread_priority::RealtimeThreadSchedulePolicy::RoundRobin,
        ),
    )
    .unwrap();
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    configure_rt_thread();
    let args = Args::parse();

    let (tx1, rx1) = tokio::sync::mpsc::unbounded_channel();
    let (tx2, rx2) = tokio::sync::mpsc::unbounded_channel();

    let task1 = ping_pong(args.show_logs, tx1, rx2);
    let task2 = ping_pong(args.show_logs, tx2, rx1);
    println!("Starting application");
    tokio::join!(task1, task2);
}

async fn ping_pong(show_logs: bool, tx: UnboundedSender<u64>, mut rx: UnboundedReceiver<u64>) {
    let mut i = 0;
    loop {
        if show_logs {
            println!("Sending {i}");
        }
        tx.send(i).unwrap();
        let v = rx.recv().await;
        if show_logs {
            println!("Received {v:?}");
        }
        i = i.wrapping_add(1);
    }
}
```

Notably, there is no unsafe code, so it's unlikely that we have a soundness issue — could be in 
our dependencies, but tokio is very well tested by today's standards. So my guess is that something 
else is causing our process to be killed.

The next couple sections introduce async Rust and real-time Linux. Feel free to 
[jump ahead](#figuring-out-the-problem) if you are already familiar with these technologies.

## What is async Rust?

Covering async Rust properly would take a signficant amount of time. This section only introduces 
the key concepts needed to understand this blog posts. If you are interested in this topic and 
would like to learn more, I recommend reading the [async book](https://rust-lang.github.io/async-book/).

Async Rust introduces a model of cooperative multitasking that performs task switching and 
scheduling on userspace. Because Rust is a system's programming language, there is no default 
implementation for the runtime task scheduler and switching. The most common async runtime is `Tokio`.
The language allows the user to define functions with defined blocking points at which a task can 
yield to the async task scheduler. The main mechanism to do this is the [`Future` trait](https://doc.rust-lang.org/std/future/trait.Future.html).

```rust
pub trait Future {
    type Output;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output>;
}

pub enum Poll<T> {
    Ready(T),
    Pending,
}
```

A `Future` is an object that can be polled as many times as needed until it is ready and resolves 
to the result of the future. T

The Rust 2018 edition introduced two keywords that relate to async Rust:
- `async`: This keyword is placed in front of a function definition to denote that the function 
returns a future. `async fn my_func()` is syntactic sugar for `fn my_func() -> impl Future<Output = ()>`.
- `await`: This keyword is used to indicate blocking operations in your asynchronous functions. 
`await` is invoked on types implementing the `Future` trait in order to poll the future until it 
is ready. This helps to avoid explicitly invoking `future.poll(...)` inside user code.

With these primitives, we can better understand the code above. A slighly simplified version is shown below:

```rust
async fn ping_pong(show_logs: bool, tx: UnboundedSender<u64>, mut rx: UnboundedReceiver<u64>) {
    let mut i = 0;
    loop {
        // if show_logs { ... }
        tx.send(i).unwrap();
        let v = rx.recv().await;
        // if show_logs { ... }
    }
}
```

The `async fn ping_pong(...)` function, when called, returns a type implementing `Future` that does 
nothing until it is `await`ed. This future, when polled (i.e.: awaited), can make progress for any 
`non-async` operations. For example, during the first call to poll, it would make progress by 
defining the mutable variable `i`, entering the loop and calling `send` on the channel. Then,
it calls `rx.recv()`, which is an async function, returning a `Future`. This future is then awaited 
and one of two things can happen:
- If the channel is not empty, it can immediately return a value, resolving to `Poll::Ready(v)`. In 
  this case, the `ping_pong` function future will continue executing, and no yield to a different task 
  happens.
- However, if the channel is empty, it returns `Poll::Pending`, causing the `ping_pong` future to also
  yield returning `Poll::Pending`, all the way until the scheduler (Tokio) is reached, which will 
  then find another task that can make progress and schedule it instead. The state of the `ping_pong`
  future will keep track of what operation it was doing, so that when it is resumed by Tokio it can 
  continue right from where it stopped.

With this you can now get a feeling of how the cooperative scheduling happens in Tokio. In a single 
thread, Tokio can be running many parallel tasks without requiring any intervention by the OS scheduler, 
which saves time that would otherwise be wasted in context switches between a process and the OS.

In summary:
- `async fn` defines a function that returns a future. They do nothing until the future is awaited.
- All code inside an `async fn` is by default synchronous. The calls to `.await` are the points at which 
the function _can_ yield to the scheduler (it does not have to if the future is already ready).

Tokio also provides primitives to poll two futures concurrently. `tokio::join!()` is used for this 
purpose in the example above.

## What is real-time Linux?

Linux was initially designed as an operating system for Desktop computers, to serve the needs of 
Linus Torvalds for a Unix replacement. However, over its lifespan, it has been used in all sorts 
of products, ranging from smartphones, servers and all sorts of embedded systems.

Because of the wide-ranging applications, Linux has evolved its process and thread scheduler to meet
the needs of these varied devices. 

Desktop Linux distributions use the Linux Completely Fair Scheduler (`CFS`), which is suited for 
interactive processes and biased towards responsiveness. This scheduler rewards interactive processes 
and penalizes processes that hog the CPU for large amounts of time.

Server Linux distributions use the Linux ...

Linux also includes a PREEMPT_RT patch which provides the capability to preempt the entire kernel, 
so that it can be used in real-time applications. 

Linux can use

# Figuring out the problem

First I tried to use observability tools like `strace`. But sadly, the behavior entirely disappeared 
when using strace. The process worked just as intended.

`journalctl` and `dmesg` also show no new messages when the process is killed. But why is it killed 
only if I run it directly and not via strace? Could be that I am slowing down the process significantly 
and reducing the likelihood of some specific interleaving somehow?

At this point, I was mostly asking myself who is killing the process. I can figure out why later.
So I set out to find it out, but how can I figure this out? Could I make sure that there is no impact
like I see with `strace`? I knew I wanted to use a very lean observability tool that minimizes the 
overhead on my process and just catches the kill syscall. This was the perfect job for `eBPF` and 
`bpftrace`.

## Introducing eBPF

`eBPF` has its origin in the Berkley Packet Filter, a technology developed for BSD that allows to 
accept/reject network packages for the purpose of packet filtering. Since its origins, Linux has 
adapted it to be a much more general-purpose virtual machine that can interpret code in the 
kernel context with some guarantees. An eBPF verifier makes sure that the program is safe to 
execute, for some definition of safe.

One of the big advantages of eBPF is that eBPF programs can be hooked on specific kernel events.
In fact, we could use the `signal_generate` tracepoint defined by the kernel to attach an eBPF program
and execute it when a signal is generated. We can use `bpftrace` to help us in defining the program.

## Using bpftrace

`bpftrace` is a utility for dynamic instrumentation in Linux that uses `eBPF` to execute small code 
snippets when a `probe` is hit. `Probes` are defined by providers, which can be quite varied. There are 
in-kernel providers like `kprobe` and `tracepoint`, user-space probes (user-statically-defined-probes or `USDTs`)
which allow programs to define their own lightweight probe points (using dynamic text program 
instrumentation), as well as other types of probes like time-based probes using the `interval` provider.

For anyone familiar with `dtrace`, `bpftrace` is a similar technology (that even uses a similar `awk`-inspired
language) for the Linux kernel.

Let's list all the available probes with:

```sh
$ sudo bpftrace -l
```

In this list you'll find potentially good candidates like `tracepoint:syscalls:sys_enter_kill`. 
This probe gets matched when a process executes a `kill` syscall, specifically on enter to the 
syscall. However, signals are not always originated by a user-space `kill` syscall, so let's try 
to find a more general one.

The list also contains `tracepoint:signal:signal_generate`. This is a tracepoint in the kernel
that triggers whenever a signal is generated, regardless of the origin of the signal. This seems 
like a much better candidate.

Probes also contain additional attached data that can be used either for displaying information or 
for filtering the probe triggers that are actually relevant for us. We can list the arguments with:

```sh
$ sudo bpftrace -lv tracepoint:signal:signal_generate
tracepoint:signal:signal_generate
    int sig
    int errno
    int code
    char comm[16]
    pid_t pid
    int group
    int result
```

Interestingly we have access to the signal number in `sig`, the name of the target process in 
`comm`, the process identifier of the target process in `pid`, and a few more fields.

With this we can already try to build our first program that prints all signals that are generated 
in our system and print some of this information when triggered. Let's define our first bpftrace 
script.

```
#!/usr/bin/bpftrace

tracepoint:signal:signal_generate
{
    printf("sending signal %d to pid %d [%s]\n",
        args->sig,
        args->pid,
        args->comm
    );
}
```

When we run this script, our kernel gets instrumented to call printf on all `tracepoint:signal:signal_generate`
events, regardless of the origin of the signal. Note that we can access the arguments of the probe by
using the `args` pointer. This is an implicitly-defined variable made available inside of every probe.

```sh
❯ sudo ./signal_tracer_simple
Attached 1 probe
sending signal 34 to pid 30837 [sssd_kcm]
sending signal 9 to pid 33210 [my-program]
sending signal 17 to pid 33013 [fish]
sending signal 17 to pid 33214 [starship]
sending signal 17 to pid 33220 [starship]
sending signal 17 to pid 33216 [starship]
sending signal 17 to pid 33213 [starship]
sending signal 17 to pid 33013 [fish]
sending signal 17 to pid 33013 [fish]
sending signal 31 to pid 32919 [StreamT~ns #117]
sending signal 31 to pid 32919 [StreamT~ns #117]
```

Ok, so we can see the signals being sent and we definitely see our `my-program` process getting 
killed with a `SIGKILL` (signal 9). But we haven't gotten any new information that we didn't already know. 
This might also be overly verbose since we are watching for all signals and not just the sigkill 
we are interested in. Let's do some changes to print only `SIGKILL`s coming from a command named 
`my-program`. For this purpose we will introduce the concept of a probe `predicate`, which allows to 
gate the body of a probe based on a given condition.

```
#!/usr/bin/bpftrace

tracepoint:signal:signal_generate
/args->comm == "my-program" && args->sig == 9/
{
    printf("sending signal %d to pid %d [%s]\n",
        args->sig,
        args->pid,
        args->comm
    );
}
```

Note that, unlike in C, bpftrace can evaluate string comparison using the operator `==` without 
falling back to pointer equality. With this, our output is lot more succint:

```sh
❯ sudo ./signal_tracer_simple
Attached 1 probe
sending signal 9 to pid 54318 [my-program]
```

Now let's extract more information from the probe. Specifically, we would like to know the source 
of the signal. `bpftrace` includes some pre-defined variables we can use for this purpose. In 
particular, [`pid`](https://bpftrace.org/docs/release_025/stdlib#pid) and 
[`comm`](https://bpftrace.org/docs/release_025/stdlib#comm).

## Linux, I trusted you

```c
static void check_thread_timers(struct task_struct *tsk,
				struct list_head *firing)
{
	/* ... */
	/*
	 * Check for the special case thread timers.
	 */
	soft = task_rlimit(tsk, RLIMIT_RTTIME);
	if (soft != RLIM_INFINITY) {
		/* Task RT timeout is accounted in jiffies. RTTIME is usec */
		unsigned long rttime = tsk->rt.timeout * (USEC_PER_SEC / HZ);
		unsigned long hard = task_rlimit_max(tsk, RLIMIT_RTTIME);

		/* At the hard limit, send SIGKILL. No further action. */
		if (hard != RLIM_INFINITY &&
		    check_rlimit(rttime, hard, SIGKILL, true, true))
			return;

		/* At the soft limit, send a SIGXCPU every second */
		if (check_rlimit(rttime, soft, SIGXCPU, true, false)) {
			soft += USEC_PER_SEC;
			tsk->signal->rlim[RLIMIT_RTTIME].rlim_cur = soft;
		}
	}
	/* ... */
}
```

# Fundamental differences between async Rust and traditional threaded code

[^1]: The Bash reference manual details all the possible values of the exit status of a process 
[here](https://www.gnu.org/software/bash/manual/bash.html#Exit-Status-1). This is an interesting 
read for anyone who is looking to understand their shell in depth.
[^2]: `man` pages are surprisingly helpful for understanding your unix-like system. Go have a look 
[the page](https://man7.org/linux/man-pages/man7/signal.7.html) and find out more about signals!
