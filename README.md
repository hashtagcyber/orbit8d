# Orbit8D

A macOS menu bar app that turns whatever your apps play into 8D audio: the music circles your head, in time with its tempo. Use headphones.

## Requirements

- macOS 14.2 or later
- Xcode (the tests need XCTest; `make app` works with the Command Line Tools alone)

## Build and run

```sh
make run
```

Click the headphones icon in the menu bar and turn on **8D audio**. macOS asks for permission to record system audio the first time.

The app is ad-hoc signed, so macOS asks for the permission again after each rebuild.

## Controls

| Control | Effect |
|---|---|
| 8D audio | On: captures all app audio, mutes the originals, plays the 8D version. Off: audio plays normally. |
| Bars per orbit | Bars of music per full circle. **Auto** picks a count that keeps one orbit between 8 and 20 seconds. |
| Width | Angle between the left and right channels as they orbit. |
| Room | Amount of reverb. Some reverb makes the sound sit outside your head. |

With no clear beat, the orbit takes 12 seconds.

## How it works

```
apps → process tap (originals muted) → ring buffer → 2 HRTF sources → headphones
                                     ↘ tempo estimator → orbit speed
```

- `SystemAudioTap`: a Core Audio process tap on everything except this app, read through a private aggregate device clocked by the output device.
- `SpatialEngine`: `AVAudioEnvironmentNode` with one HRTF source per channel. The orbit rotates the listener, which moves both sources together.
- `TempoEstimator`: autocorrelation of an onset-strength envelope over the last 12 seconds, re-estimated every 2 seconds.
- `OrbitController`: maps tempo to rotation speed and eases between speeds so the position never jumps.

## Limits

- The orbit matches the tempo, but it is not aligned to downbeats.
- Assumes 4/4 time.
- Volume keys control the 8D output; per-app volume is unchanged.

## Test

```sh
make test
```
