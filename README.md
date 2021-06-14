<h1 align="center">zanzara</h1>
<p align="center">
    <a href="LICENSE"><img src="https://badgen.net/github/license/rbino/zanzara" /></a>
</p>

An MQTT client written in Zig.

*Warning: this library is currently experimental and will probably burn your house down if you use
it to control your heating*

## Features

- [x] MQTT 3.1.1 packet serialization/deserialization
- [x] TCP connection (no SSL)
- [x] QoS 0 Publish
- [x] Subscribe (but no way of receiving data right now)
- [ ] Everything else (including a more detailed list of what's missing)

## Example

You can run the example with:

```
zig run example.zig
```

You can use `mosquitto_sub` to verify that the code is actually publishing:

```
mosquitto_sub -h "test.mosquitto.org" -t "zig/zanzara" -d
```
