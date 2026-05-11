$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

docker buildx build --platform linux/arm64 --provenance=false --sbom=false -t sshgate:latest --load .

# Чистим возможный остаток от прошлых запусков (иначе skopeo упадёт «can't modify existing image»)
if (docker volume ls --filter name=^imgvol$ -q) {
  docker volume rm imgvol | Out-Null
}
docker volume create imgvol | Out-Null

docker run --rm `
  -v imgvol:/out `
  -v /var/run/docker.sock:/var/run/docker.sock `
  quay.io/skopeo/stable:latest copy `
  docker-daemon:sshgate:latest `
  docker-archive:/out/image.tar:sshgate:latest

docker run --rm `
  -v imgvol:/data `
  -v "${PWD}:/host" `
  --entrypoint sh `
  quay.io/skopeo/stable:latest `
  -c "gzip -c /data/image.tar > /host/sshgate.tar.gz"

docker volume rm imgvol | Out-Null

Write-Host "Done: $PWD\sshgate.tar.gz"
