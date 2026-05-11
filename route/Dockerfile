FROM alpine:3.20 AS build-hev
RUN apk add --no-cache build-base git linux-headers
RUN git clone --recursive --depth 1 https://github.com/heiher/hev-socks5-tunnel.git /hev && \
    cd /hev && make && strip bin/hev-socks5-tunnel

FROM alpine:3.20 AS build
RUN apk add --no-cache openssh-client iproute2-minimal
RUN mkdir /out && \
    cp /usr/bin/ssh /out/ && \
    cp /bin/busybox /out/ && \
    cp /sbin/ip /out/ && \
    ldd /usr/bin/ssh | awk '/=>/{print $3}' | xargs -I{} cp {} /out/ && \
    ldd /bin/busybox | awk '/=>/{print $3}' | xargs -I{} cp -n {} /out/ && \
    ldd /sbin/ip | awk '/=>/{print $3}' | xargs -I{} cp -n {} /out/ && \
    cp /lib/ld-musl-*.so.1 /out/

FROM scratch
COPY --from=build /out/ld-musl-*.so.1 /lib/
COPY --from=build /out/lib*.so* /lib/
COPY --from=build /out/ssh /usr/bin/ssh
COPY --from=build /out/ip /sbin/ip
COPY --from=build /out/busybox /bin/busybox
COPY --from=build-hev /hev/bin/hev-socks5-tunnel /usr/bin/hev-socks5-tunnel
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/sh"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/sleep"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/echo"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/date"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/chmod"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/cat"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/nc"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/grep"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/head"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/usr/bin/awk"]
RUN ["/bin/busybox", "mkdir", "-p", "/etc/ssh", "/root/.ssh", "/tmp"]
RUN ["/bin/busybox", "sh", "-c", "echo 'root:x:0:0:root:/root:/bin/sh' > /etc/passwd && echo 'root:x:0:' > /etc/group"]
COPY entrypoint.sh /entrypoint.sh
RUN ["/bin/busybox", "chmod", "+x", "/entrypoint.sh"]
ENTRYPOINT ["/entrypoint.sh"]
