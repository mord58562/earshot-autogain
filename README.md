# Earshot AutoGain

An AUv3 audio effect for macOS that rides gain slowly enough not to be heard.
A peak follower with a long release steers the level toward a target at
0.2 dB/s downward and 0.02 dB/s upward, with a 5 ms look-ahead brickwall
limiter behind it as the backstop.

It is the auto-preamp from [Earshot](https://github.com/mord58562/earshot)
lifted out of the menubar app and rebuilt as a plug-in, with the EQ removed
and the limiter, multichannel support and full parameter automation added.

Requires Apple Silicon and macOS 13 or later. No Xcode project, no package
manager, no dependencies beyond the Xcode Command Line Tools.

## Install

```bash
xcode-select --install     # if the Command Line Tools are not present
git clone https://github.com/mord58562/earshot-autogain.git
cd earshot-autogain
chmod +x build.sh install.sh
./install.sh
```

The installer builds the bundle, copies it to `/Applications`, registers the
extension with `pluginkit`, flushes the Audio Unit component cache, and opens
the container app so you can confirm registration. Quit the container app once
it reads *Registered*. It does not need to stay running; macOS only needs it
present in `/Applications` to discover the extension.

The plug-in appears in any AUv3 host under **Audio Unit Effects** as
**Earshot: AutoGain**. Hosts enumerate Audio Units at launch, so quit and
reopen the host if it was already running.

## Where to put it in the chain

```
Source -> EQ or boost -> AutoGain -> Output
```

AutoGain is a feedback leveller: it measures its own output and trims until
the envelope settles at the target. It has to sit downstream of whatever is
doing the boosting. Placed before the boost it sees an unboosted signal,
concludes there is nothing to do, and parks at 0 dB.

Its internal limiter means a separate downstream limiter is optional. If your
chain already ends in one, leave it; AutoGain riding the level should keep it
from engaging.

## Latency

The plug-in reports **5 ms** of latency at all times, whether the limiter is
enabled or not. The look-ahead delay line runs unconditionally so that
toggling the limiter never renegotiates host compensation and never clicks.
Hosts with delay compensation handle this automatically. If you are running a
parallel path by hand, compensate it by 5 ms.

## Parameters

| Parameter | Range | Default | What it does |
|---|---|---|---|
| Target | -24 to 0 dB | -3 dB | Peak level the leveller aims for |
| Max Boost | 0 to 24 dB | 0 dB | Upper gain clamp. 0 means it never adds gain |
| Max Cut | -48 to 0 dB | -24 dB | Lower gain clamp |
| Fall Rate | 0.02 to 3 dB/s | 0.2 dB/s | How fast gain comes down |
| Rise Rate | 0.002 to 3 dB/s | 0.02 dB/s | How fast gain goes back up |
| Clip Escape | 1 to 10 x | 2.5 x | Fall-rate multiplier while peaks are at or above -0.04 dBFS |
| Release | 0.25 to 120 s | 3 s | Envelope decay. Longer means it holds its memory of a loud passage for longer |
| Gate | -90 to -20 dB | -56 dB | Below this the gain freezes rather than drifting on silence |
| Bypass Gain | on/off | off | Bypasses the leveller. The limiter stays active |
| Limiter | on/off | on | The look-ahead brickwall limiter |
| Ceiling | -12 to 0 dB | -1 dB | Limiter ceiling |
| Lim Release | 5 to 1000 ms | 80 ms | Limiter release |

All twelve are automatable and rampable.

### Why the rates are asymmetric

Earshot moved gain at one rate in both directions. That is defensible when
gain is hard-capped at unity, but not on music: a quiet passage lasting a
minute recovers a full 12 dB at 0.2 dB/s, and although no individual moment is
perceptible, the arrival is. Downward movement is protection and needs to be
prompt. Upward movement is recovery and can afford to take a minute.

If you want the original symmetric behaviour, load the **Earshot Classic**
preset.

## Presets

| Preset | For |
|---|---|
| Earshot Classic | Symmetric 0.2 dB/s in both directions, matching the original Earshot auto-preamp |
| Volume Guard | The shipping default. Attenuation only, slow recovery |
| Source Leveller | Target -6 dB, up to 12 dB of boost, 20 s release. For material with genuinely inconsistent source levels |

## The Reseed button

Slow rise means an intentional switch to a much quieter source takes minutes
to catch up. Reseed jumps the gain straight to where the leveller would
eventually put it, once, then hands control back. It is a manual control only
and is not automatable.

## How it works

**Leveller.** Every 40 ms the kernel takes the loudest sample seen across all
channels since the last tick, measured post-gain and pre-limiter. That peak
feeds an envelope with instant attack and an exponential release set by the
Release parameter. If the envelope is below the gate, gain freezes. Otherwise
the gain moves toward the target by at most Fall Rate or Rise Rate multiplied
by the elapsed time. There is no fast-attack path: a transient that clips
still only moves gain by its normal fractional-dB step on that tick.

Measuring pre-limiter is deliberate. Measuring the limiter's output would mean
the leveller never learns it is driving into the ceiling.

Gain is interpolated per sample across each buffer, so parameter and gain
changes never step.

**Limiter.** A 5 ms look-ahead brickwall with instant attack, a hold of exactly
the look-ahead window before release begins, and gain reduction linked across
channels so the stereo image does not shift. The hold matters: without it the
envelope relaxes while the peak that set it is still inside the delay line,
which measures at about 0.06 dB of overshoot.

There is no hard clipper. With the limiter disabled, overs pass through
untouched.

**Channels.** Up to 8, with one linked gain driven by the loudest. Input and
output channel counts must match.

**Sample rate.** Everything rate-dependent is derived at
`allocateRenderResources` time. Envelope decay uses measured elapsed time
rather than an assumed tick length, so behaviour is identical at any sample
rate and buffer size.

The render path allocates nothing and takes no locks.

## The display

The plug-in window shows current gain reduction as a bar and a numeric
readout, an orange dot that lights when the limiter is working, and a 44-band
log-spaced spectrum of the post-limiter signal. The spectrum analysis only
runs while the window is on screen.

## Component identifiers

```
type          aufx
subtype       agn1
manufacturer  Ersh
bundle        com.mord58562.EarshotAutoGain.AutoGainAU
```

## Troubleshooting

The host does not list it:

```bash
auval -v aufx agn1 Ersh                          # validate
auval -a | grep -i earshot                       # confirm registration
pluginkit -mAvvv -p com.apple.AudioUnit-UI | grep -i autogain
killall -9 AudioComponentRegistrar               # flush the cache by hand
```

Then quit and reopen the host. If `auval` passes but the host still does not
list it, the host is AUv2-only; there is no AUv2 build.

The app must stay in `/Applications`. Moving or deleting it deregisters the
extension.

## Build without installing

```bash
./build.sh
```

Produces `Earshot AutoGain.app` in the working directory. The build is two
`swiftc` calls and an ad-hoc `codesign`; the extension is signed before the
outer bundle, because signing the outer first invalidates it as soon as the
inner changes.

## Licence

MIT.
