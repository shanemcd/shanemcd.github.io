---
layout: post
title:  "IRC Bouncer with ZNC and Docker"
date:   2016-03-11
---

I've been hanging out on the Freenode and Mozilla IRC networks recently. I forgot how awesome it is to talk to strangers on the internet.

In the past I’ve typically been a casual IRC user. Occasionally popping in to ask the random programming question, but it was never a primary method of communication for me.

I really started to view it differently when I joined the `#rust-beginners` channel on the Mozilla network. I had struggled with a simple problem for several hours one Saturday morning, and out of desperation I posted a question accompanied by a gist. Someone answered me within 2 minutes, and I was on my way. This was awesome, and I wanted to be a part of it.

Fast forward a couple months, and I’m slowly getting acclimated to life with IRC.

Naturally, one of the first challenges I experienced with IRC was the lack of "history". Yes, you can find logs for many channels on sites like [BotBot](https://botbot.me), but you're not going to find everything.

This is when I rolled up my sleeves and looked into what it would take to set up a [BNC](https://en.wikipedia.org/wiki/BNC_(software)) (short for bouncer). I had heard about the concept years ago, but was always intimidated because I did not know the first thing about setting up my own server. Luckily, it’s not as hard as I had once thought.

So here we go, a crash course in setting up a BNC with [ZNC](http://znc.in).

Here’s what you’re gonna need:

- A server (I used a $5/mo Fedora box from Digital Ocean)
- A domain or subdomain pointing to this server.
- Docker ([https://www.docker.com](https://www.docker.com))
- Let’s Encrypt ([https://letsencrypt.org](https://letsencrypt.org))

I won’t cover the download / installation of these tools, because you should always reference official documentation rather than copying and pasting from some old blog post!

### Running ZNC with Docker

#### SSL/TLS

We want our connection to our BNC to be secure, so we’re going to use Let’s Encrypt, which is a free way to obtain signed certificates.

Once you have installed Let’s Encrypt, generate your certificates:

```bash
$ letsencrypt certonly
```

Follow the instructions on screen, and you’re good to go.

Next, we need to do some work to get the certs into shape for  ZNC, the BNC software we will be using:

```bash
$ mkdir -p ~/.znc && \
    cat /etc/letsencrypt/live/irc.example.com/{privkey,cert,chain}.pem > ~/.znc/znc.pem
```

Now we’re ready to run ZNC:

```
$ sudo docker run --restart=always -d -p 36667:6667 -v $HOME/.znc:/znc-data jimeh/znc
```

The first time we start the server, the configuration will be written to `~/.znc` on the host. By default, SSL will _not_ be enabled. You must edit `~/.znc/configs/znc.conf` and set `SSL` to `true`.

Now we need to restart the server by grabbing the container id from `docker ps` and running `docker restart CONTAINER_ID`.

You should now be able to visit `https://irc.example.com:36667` and configure ZNC. See the [`docker-znc`](https://github.com/jimeh/docker-znc) readme for the default credentials and more information.

You are now well on your way to having a fully functional and secure BNC. You’ll just need to configure your network(s), and update your IRC client with your ZNC credentials.

Happy chatting! If you have any questions, feel free to reach out to me on [Twitter](http://twitter.com/anatomyofashane).
