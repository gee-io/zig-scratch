# zig-scratch
A place for random zig code

```bash
$ brew install zig --head
$ zig version
0.10.0-dev.520+5cf918143

```

```bash
wget https://ziglang.org/builds/zig-linux-aarch64-0.10.0-dev.513+029844210.tar.xz
tar xf zig-*.tar.xz
rm zig-*.tar.xz
export PATH="$HOME/zig-linux-aarch64-0.10.0-*/zig:$PATH"
```

```bash


zig_build=$(uname -ms | tr '[[:upper:]] ' '[[:lower:]]-')

curl -sS https://ziglang.org/download/index.json | jq ".master[\"$zig_build\"]"
```
