<h1 align="center">zanzara</h1>
<p align="center">
    <a href="LICENSE"><img src="https://badgen.net/github/license/rbino/zanzara" /></a>
</p>

An allocation-free, I/O-agnostic MQTT client written in Zig.

_Warning: this is a work in progress, the API is subject to change_

## Features

- [x] MQTT 3.1.1 client packet serialization/deserialization
- [x] Ping handling
- [x] Subscribe and receive data
- [ ] Publish
- [ ] Everything else (including a more detailed list of what's missing)

## Example

You can run the example with:

```
zig run example.zig
```

You can use `mosquitto_pub` to publish to the topic to verify the client is subscribed

```
mosquitto_pub -h "test.mosquitto.org" -t "zig/zanzara" -m "Hello, MQTT"
```
