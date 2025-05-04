---
title: Debuging a Golang project on a Fedora Atomic Desktop (with Emacs and Dape)
---
A couple months ago, I tried to get [Dape](https://github.com/svaante/dape) working with a Golang project and ran into a couple of problems that prevented me from being able to use it. Today I decided to revisit it, and I'm glad I did, because it was one of the last remaining reasons I had for ever needing to open VSCode.
## First attempt at using Dape with a Golang project
### Problem 1 - passing arguments
In the top-level of my repo, I created the file `.dir-locals.el` with the following content:

```lisp
((go-mode . ((dape-configs .
        ((go-debug-main
          modes (go-mode go-ts-mode)
          command "dlv"
          command-args ("dap" "--listen" "127.0.0.1:55878" "--log-dest" "/tmp/dlv.log")
          command-cwd "/home/shanemcd/github/GoogleContainerTools/skaffold/examples/simple-artifact-dependency"
          host "127.0.0.1"
          port 55878
          :request "launch"
          :mode "debug"
          :type "go"
          :showLog "true"
          :program "/home/shanemcd/github/GoogleContainerTools/skaffold/cmd/skaffold/skaffold.go"
          :args ("build")))))))

```

I am using Google's [Skaffold](https://skaffold.dev/) here in my example, but any program that accepts command line arguments will serve the purpose.

With this config in place, I navigated to the program's entrypoint (`cmd/skaffold/skaffold.go`) and was prompted with this:

```
The local variables list in /home/shanemcd/github/GoogleContainerTools/skaffold/
or .dir-locals.el contains values that may not be safe (*).

Do you want to apply it?  You can type
y  -- to apply the local variables list.
n  -- to ignore the local variables list.
!  -- to apply the local variables list, and permanently mark these
      values (*) as safe (in the future, they will be set automatically.)
i  -- to ignore the local variables list, and permanently mark these
      values (*) as ignored
+  -- to apply the local variables list, and trust all directory-local
      variables in this directory

  * dape-configs : ((go-debug-main modes (go-mode go-ts-mode) command "dlv" command-args ("dap" "--listen" "127.0.0.1:55878" "--log-dest" "/tmp/dlv.log") command-cwd "/var/home/shanemcd/github/GoogleContainerTools/skaffold/examples/simple-artifact-dependency" host "127.0.0.1" port 55878 :request "launch" :mode "debug" :type "go" :showLog "true" :program "/var/home/shanemcd/github/GoogleContainerTools/skaffold/cmd/skaffold/skaffold.go" :args ("build")))
```

After typing `y` and pressing `Return`. With the file open, I then ran `M-x dape` and saw the following output in the `*dape-repl*` buffer:

```
* Welcome to Dape REPL! *
Available Dape commands: debug, next, continue, pause, step, out, up, down, threads, stack, modules, sources, breakpoints, scope, watch, restart, kill, disconnect, quit
Empty input will rerun last command.

* Process launched /var/home/shanemcd/github/GoogleContainerTools/skaffold/examples/simple-artifact-dependency/__debug_bin1126826703 *
Type 'dlv help' for list of commands.
Hello
A tool that facilitates continuous development for Kubernetes applications.

  Find more information at: https://skaffold.dev/docs/getting-started/

End-to-end Pipelines:
  run                 Run a pipeline
  dev                 Run a pipeline in development mode
  debug               Run a pipeline in debug mode

Pipeline Building Blocks:
  build               Build the artifacts
  test                Run tests against your built application images
  deploy              Deploy pre-built artifacts
  delete              Delete any resources deployed by Skaffold
  render              Generate rendered Kubernetes manifests
  apply               Apply hydrated manifests to a cluster
  verify              Run verification tests against skaffold deployments

Getting Started With a New Project:
  init                Generate configuration for deploying an application

Other Commands:
  completion          Output shell completion for the given shell (bash, fish or zsh)
  config              Interact with the global Skaffold config file (defaults to `$HOME/.skaffold/config`)
  diagnose            Run a diagnostic on Skaffold
  exec                Execute a custom action
  fix                 Update old configuration to a newer schema version
  schema              List JSON schemas used to validate skaffold.yaml configuration
  survey              Opens a web browser to fill out the Skaffold survey
  version             Print the version information

Usage:
  skaffold [flags] [options]

Use "skaffold <command> --help" for more information about a given command.
Use "skaffold options" for a list of global command-line options (applies to all commands).
```

Well, that didn't work as I had expected.

Reading over the `dape` README, I saw this under the `C, C++ and Rust - lldb-dap` heading:

> To pass arguments, use `:args ["arg1" "arg2" ..]`

At first I did not try this because I assumed if it also applied to other languages it would have been called out explicitly, but sure enough, it worked after running `dape` and then appending my args:

```
go-debug-main :args ["build"]
```

I then tried to update my `.dir-locals.el` with the bracket notation:

```diff
diff --git a/.dir-locals.el b/.dir-locals.el  
index 65e164b..9995c3a 100644  
--- a/.dir-locals.el  
+++ b/.dir-locals.el  
@@ -11,4 +11,4 @@  
          :type "go"  
          :showLog "true"  
          :program "/home/shanemcd/github/GoogleContainerTools/skaffold/cmd/skaffold/skaffold.go"  
-          :args ("build")))))))  
+          :args ["build"]))))))
```

... and it worked! 🎉 (but also🤦‍♂️)

```
* Welcome to Dape REPL! *
Available Dape commands: debug, next, continue, pause, step, out, up, down, threads, stack, modules, sources, breakpoints, scope, watch, restart, kill, disconnect, quit
Empty input will rerun last command.

* Process launched /var/home/shanemcd/github/GoogleContainerTools/skaffold/examples/simple-artifact-dependency/__debug_bin2338563526 build *
Type 'dlv help' for list of commands.
Generating tags...
 - app -> app:v2.15.0-4-g8c00b98d7
 - base -> base:v2.15.0-4-g8c00b98d7
Checking cache...
 - app: Not found. Building
 - base: Not found. Building
Starting build...
Building [base]...
Sending build context to Docker daemon  3.072kB

Step 1/3 : FROM alpine:3
 ---> aded1e1a5b37
Step 2/3 : COPY hello.txt .
 ---> Using cache
 ---> 5739d7557ae4
Step 3/3 : CMD ["./app"]
 ---> Using cache
 ---> 17979f81cffb
Successfully built 17979f81cffb
Successfully tagged base:v2.15.0-4-g8c00b98d7
The push refers to repository [docker.io/library/base]
23deea18e759: Preparing
08000c18d16d: Preparing
Process 160667 has exited with status 1
Detaching
* Session terminated *
```

### Problem 2 - breakpoints not working

Now with the command invocation working, I proceeded with trying to set a breakpoint in the Skaffold code with `dape-breakpoint-toggle C-x C-a b`. Doing that and then re-running `dape`, I was surprised to see that the breakpoint did not hit as I was expecting.

After describing my problem to ChatGPT, it inferred from our previous chats that I was using Fedora Kinoite, and it pointed out right away that symlinks (Fedora Atomic Desktops link `/home/` to `/var/home`) were known to cause problem in debuggers. After a quick search, that was easy to confirm after locating [this note](https://github.com/golang/vscode-go/blob/master/docs/debugging.md#debug-symlink-directories) in the `vscode-go` docs. I was able to get around this by setting `HOME` to the full path when in my `.dir-locals.el` 

```diff
diff --git a/.dir-locals.el b/.dir-locals.el  
index 9995c3a..fba8c9f 100644  
--- a/.dir-locals.el  
+++ b/.dir-locals.el  
@@ -3,12 +3,12 @@  
          modes (go-mode go-ts-mode)  
          command "dlv"  
          command-args ("dap" "--listen" "127.0.0.1:55878" "--log-dest" "/tmp/dlv.log")  
-          command-cwd "/home/shanemcd/github/GoogleContainerTools/skaffold/examples/simple-artifact-dependency"  
+          command-cwd "/var/home/shanemcd/github/GoogleContainerTools/skaffold/examples/simple-artifact-dependency"  
          host "127.0.0.1"  
          port 55878  
          :request "launch"  
          :mode "debug"  
          :type "go"  
          :showLog "true"  
-          :program "/home/shanemcd/github/GoogleContainerTools/skaffold/cmd/skaffold/skaffold.go"  
+          :program "/var/home/shanemcd/github/GoogleContainerTools/skaffold/cmd/skaffold/skaffold.go"  
          :args ["build"]))))))
```

And when launching emacs:

```
$ env HOME=/var/home/shanemcd emacs
```

Seeking a more long-term solution, I was able to add this to my emacs configuration, which handles setting `HOME` correctly whenever it is symlinked:

```lisp
(when-let ((real-home (file-truename (getenv "HOME"))))
  (when (not (string= (getenv "HOME") real-home))
    (setenv "HOME" real-home)))
```

I still have a lot more to learn, but with this, I am at least able to set breakpoints in my Golang application, step through the code, and inspect variables. I hope this blog post proves to be useful for others, but if nothing else I will be able to copy + paste these configs the next time I lose them. 🙂