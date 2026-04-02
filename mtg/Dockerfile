FROM golang:1-alpine AS build-mtg
RUN CGO_ENABLED=0 go install -ldflags="-s -w" github.com/9seconds/mtg/v2@latest

FROM alpine:3.20 AS build
RUN apk add --no-cache openssh-client ca-certificates
RUN mkdir /out && \
    cp /usr/bin/ssh /out/ && \
    cp /bin/busybox /out/ && \
    ldd /usr/bin/ssh | awk '/=>/{print $3}' | xargs -I{} cp {} /out/ && \
    ldd /bin/busybox | awk '/=>/{print $3}' | xargs -I{} cp -n {} /out/ && \
    cp /lib/ld-musl-*.so.1 /out/

FROM scratch
COPY --from=build /out/ld-musl-*.so.1 /lib/
COPY --from=build /out/lib*.so* /lib/
COPY --from=build /out/ssh /usr/bin/ssh
COPY --from=build /out/busybox /bin/busybox
COPY --from=build-mtg /go/bin/mtg /usr/bin/mtg
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/sh"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/sleep"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/echo"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/date"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/chmod"]
RUN ["/bin/busybox", "ln", "-s", "/bin/busybox", "/bin/cat"]
RUN ["/bin/busybox", "mkdir", "-p", "/etc/ssh", "/root/.ssh", "/tmp"]
RUN ["/bin/busybox", "sh", "-c", "echo 'root:x:0:0:root:/root:/bin/sh' > /etc/passwd && echo 'root:x:0:' > /etc/group"]
COPY entrypoint.sh /entrypoint.sh
RUN ["/bin/busybox", "chmod", "+x", "/entrypoint.sh"]
ENTRYPOINT ["/entrypoint.sh"]
