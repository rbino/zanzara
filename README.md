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
- [x] Publish (QoS 0 only)
- [x] Unsubscribe
- [ ] Everything else (including a more detailed list of what's missing)

## Example

You can run the example with:

```
zig run example.zig
```

You can use `mosquitto_sub` to see the message that is published by the example just after the
connection

```
mosquitto_sub -h "mqtt.eclipseprojects.io" -t "zig/zanzara_out"
```

You can use also `mosquitto_pub` to publish to the topic the example subscribes to

```
mosquitto_pub -h "mqtt.eclipseprojects.io" -t "zig/zanzara_in" -m "Hello, MQTT"
```
