# Sharelist — List Sharing App

Server and client (native and web) for sharing lists of things.

Uses CRDTs to merge simultaneous changes.

## Testing Locally

Run the server: `zig build serve-native`

Run the native client: `zig build run -- http://localhost:3000/sharelist/list?id=abcdef00`

### Testing Web Client

Run the server: `zig build serve`

Browser open `http:localhost:3000/sharelist/?id=abcdef00`

## Add New List

Create an empty file with an 8 char lowercase hex name in lists: `touch lists/abcdef01`

## Deploying

Compile server and web:
`zig build compile-server -Doptimize=fast`
`zig build web -Doptimize=small`

Copy files:
```
cd zig-out/bin
scp server index.html web.js web.wasm <your server>
```

Run server:
`./server index.html web.js web.wasm`
