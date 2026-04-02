FROM alpine:3.20 AS build
RUN apk add --no-cache openssh-client git build-base
# Собираем 3proxy
RUN git clone https://github.com/3proxy/3proxy.git /3proxy && \
    cd /3proxy && make -f Makefile.Linux && strip bin/3proxy
# Собираем список всех нужных файлов
RUN mkdir /out && \
    cp /usr/bin/ssh /out/ && \
    cp /bin/busybox /out/ && \
    cp /3proxy/bin/3proxy /out/ && \
    ldd /usr/bin/ssh | awk '/=>/{print $3}' | xargs -I{} cp {} /out/ && \
    ldd /bin/busybox | awk '/=>/{print $3}' | xargs -I{} cp -n {} /out/ && \
    ldd /3proxy/bin/3proxy | awk '/=>/{print $3}' | xargs -I{} cp -n {} /out/ && \
    cp /lib/ld-musl-*.so.1 /out/

FROM scratch
COPY --from=build /out/ld-musl-*.so.1 /lib/
COPY --from=build /out/lib*.so* /lib/
COPY --from=build /out/ssh /usr/bin/ssh
COPY --from=build /out/3proxy /usr/bin/3proxy
COPY --from=build /out/busybox /bin/busybox
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/sh"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/sleep"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/echo"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/date"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/chmod"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/cat"]
RUN ["/bin/busybox", "mkdir", "-p", "/etc/ssh", "/root/.ssh", "/tmp", "/var/log"]
RUN ["/bin/busybox", "sh", "-c", "echo 'root:x:0:0:root:/root:/bin/sh' > /etc/passwd && echo 'root:x:0:' > /etc/group"]
COPY entrypoint.sh /entrypoint.sh
RUN ["/bin/busybox", "chmod", "+x", "/entrypoint.sh"]
ENTRYPOINT ["/entrypoint.sh"]
