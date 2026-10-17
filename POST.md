---
title: I built the running coach Nike wouldn't, and it runs on my phone
published: false
tags: devchallenge, hf26challenge, ai, ios
---

*This is a submission for the [Hacktoberfest Open-Source AI Challenge: Side Hustle](https://dev.to/challenges/hacktoberfest-week2-2026-10-12)*

## What I Built

I run with Nike Run Club. It tracks every run well, but its plans aren't personal. They don't know my heart rate zones, my actual paces, or what my last few weeks looked like. A tempo session says "comfortably hard" whether my resting heart rate is 50 or 70, and the plan doesn't notice when I miss a week or double my mileage. I wanted a coach that looks at my data and changes the plan because of it.

**OpenStride** is an iOS running coach that reads your data from Apple Health and plans your week around it:

- **Heart rate zones** from your resting HR and the highest HR seen in your own runs (Karvonen)
- **Pace zones** from your best recent effort (Jack Daniels' VDOT)
- **Training load** per run and your 7-day vs 28-day load ratio
- **HR drift** between the first and second half of each run
- **How much of last week you actually did**

Every week, Gemma (Google's open-weight model) reviews those signals, adjusts the plan, and tells you why in plain words. It runs on the iPhone through MLX. No account, no server, and your health data never leaves the phone.

Who would pay: adaptive training plans are already a paid category (Runna, TrainingPeaks), sold as monthly subscriptions. OpenStride's running cost per user is zero because the model runs on the phone, so it can be a one-time purchase.

## Demo

**Demo page with the full 60 s video: [ansh-saini.github.io/open-stride](https://ansh-saini.github.io/open-stride)**

Recorded on my iPhone 13 Pro with a sample runner who doubled their mileage last week. Gemma 3 4B runs on the phone; the 20-second planning step is sped up.

![OpenStride demo](https://raw.githubusercontent.com/ansh-saini/open-stride/main/screenshots/openstride-demo.gif)

| The week | A session | Signals | What the coach saw |
|---|---|---|---|
| ![plan](https://ansh-saini.github.io/open-stride/media/iphone-week.png) | ![session](https://ansh-saini.github.io/open-stride/media/iphone-session.png) | ![signals](https://ansh-saini.github.io/open-stride/media/iphone-signals.png) | ![prompt](https://ansh-saini.github.io/open-stride/media/iphone-coach-saw.png) |

## Code

{% github ansh-saini/open-stride %}

## How I Built It

### Math in code, judgment in the model

Small models are bad at arithmetic and good at reading a situation. I didn't want a 4B model inventing paces or mileage, so I split the work:

1. **CoachKit** (pure Swift, unit tested) computes zones, paces, load and drift, then builds a draft week: phase (base, build, peak, taper), weekly volume, a long run, quality sessions.
2. Code turns the metrics into **signals** with fixed thresholds, each one OK or FLAG. For example: `acute_chronic_load_ratio = 1.98 -> FLAG: above 1.5, injury risk`.
3. **Gemma decides.** It sees the signals and the draft, and picks from a small action set: cut volume, slow easy pace, `make_easy`, `shorten` or `drop` a day, each with a reason.
4. **Guardrails** apply the decision and override anything unsafe. No flag means the draft stands. A flag with too small a response gets a floor. The long run can't be dropped.
5. **Gemma explains.** A second call writes the note from facts that code computed by diffing the draft against the final plan. Code writes the first sentence ("Your heart rate drifted 7.7% during recent runs."), and Gemma continues it. The note always matches what you see.

If the model fails, a rule-based coach writes the week, so the app never breaks.

### An eval harness, because "looks fine" isn't a test

I built six synthetic runners with seeded histories and an expected coach behavior for each:

| Runner | Signal | A good coach should |
|---|---|---|
| steady | all in range | keep progressing |
| overreaching | load ratio 1.98 | cut volume, max one hard day |
| detrained | 21 days off | no hard sessions |
| hr_drift | 7.7% drift | slow easy pace |
| missed_sessions | did 20% of last week | not add volume |
| beginner | 8 km a week | progress gently |

`coach-eval` runs them through Ollama, and `mlx-eval` runs them through the exact MLX weights the phone uses. Each run is scored on whether the decision parsed, whether the final plan is right, whether the model got it right without a guardrail floor, and whether the note cites a real number.

| Coach | Runs | Valid | Final plan right | Model right on its own | Note matches plan | Note cites the flagged number | Avg time |
|---|---|---|---|---|---|---|---|
| rules | 6 | 100% | 100% | 100% | 100% | 100% | 0.0s |
| gemma3:1b (Ollama) | 18 | 100% | 100% | 33% | 100% | 100% | 1.0s |
| gemma3:4b (Ollama) | 18 | 100% | 100% | 100% | 100% | 100% | 4.8s |
| Gemma 3 4B (on-device) | 18 | 100% | 100% | 100% | 100% | 100% | 8.0s |
| Gemma 3 1B (on-device) | 18 | 100% | 100% | 33% | 100% | 100% | 4.3s |

"On its own" means right before any guardrail floor stepped in. Times are on an M2 Pro; on-device rows use the same 4-bit MLX weights the iPhone downloads. Gemma 1B gives safe plans only because of the guardrails, so 4B is the default.

What the harness caught, in order:

- **Gemma deleted the week.** Given a "rest" action, it removed the long run and once took a runner to 0 km. The action is now `drop`, the long run can't be dropped, and only one run per week can go.
- **Gemma copied my JSON example.** The example showed a 20% cut and a Thursday change, so it cut volume for healthy runners and edited Thursdays that didn't exist. A neutral example fixed it.
- **Sign confusion.** "Slow easy runs by 10 s" came back as `-10`. I renamed the field to `slow_easy_pace_by_sec` and treat the sign as intent.
- **MLX doesn't constrain output.** Ollama enforces a JSON schema; MLX doesn't. On-device 4B scored 33% valid until I made the decoder accept the shapes Gemma actually produces (`"changes": ["Wed: make_easy ..."]`).
- **Messages that contradicted the plan.** When a guardrail rejected a change, the note still described it. That led to the two-step decide-then-explain design.
- **Gemma copied my instructions.** Told to "start with" a sentence, it sometimes wrote 'Start with "...' into the note. Now code writes that sentence and Gemma only continues.
- **Gemma 1B can't judge.** It returns "no change" for nearly every runner. The guardrails keep it safe, but 4B is the coach worth shipping.

### Making a 4B model fit on a 6 GB iPhone

The first real-device run died. The jetsam report showed iOS killing OpenStride at 4.16 GB for page shortage on my iPhone 13 Pro. The weights are 2.4 GB, so most of the rest was prompt processing: Gemma's vocabulary is 262k tokens, and MLX prefilled 512 prompt tokens at a time. I measured peak memory on my Mac for different step sizes:

| Prefill step | Peak MLX memory |
|---|---|
| 512 | 3,144 MB |
| 64 | 2,806 MB |
| 32 | 2,763 MB |

At 64 tokens per step it fits. A full plan (both Gemma calls) now takes about 20 seconds on the 13 Pro. In case a phone still runs out of memory, the app writes a marker file before generating. If it launches and finds the marker, it switches to Gemma 3 1B and tells you why instead of crashing again.

### Real data is messier than test data

My own runs exposed two things the personas didn't. None of my runs from the last four weeks have heart rate recorded, so the drift signal simply isn't there, and the coach has to work without it. And my "best effort" wasn't all-out, so the race formula underrated my fitness. Now, when heart rate exists, VDOT is also estimated from pace and heart rate reserve, and the higher estimate wins.

### Testing the real HealthKit path

The simulator has no runs, so a debug-only seeder writes a synthetic runner into Apple Health as real workouts with heart rate samples. An XCUITest launches the app, taps through the Health permission sheets, reads the data back through the real HealthKit queries, plans the week with Gemma and checks the screens. HR drift computed from those raw samples comes out at 7.7%, matching the persona.

### Stack

SwiftUI, HealthKit, Swift Charts, XCUITest on simulator and device, [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) with `mlx-community/gemma-3-text-4b-it-4bit` (2.6 GB, downloaded once), Ollama for the simulator and evals, XcodeGen.

## Why Does Open Innovation Matter?

**Privacy that holds up.** Heart rate, resting heart rate and VO2 max are health data. With an open-weight model on the device, "your data never leaves your phone" is a property of the architecture, not a line in a privacy policy. A closed API can't offer that.

**Zero marginal cost.** Every plan runs on the phone's GPU. No per-token bill means a solo developer can price this as a one-time purchase instead of a subscription that has to cover inference.

**Works offline.** After the one-time download it works on a trail with no signal, which is where runners are.

**Inspectable and swappable.** The Insights screen shows exactly what the coach saw and what it answered. Because the weights are open, I could test the same model on my Mac, in the simulator and on the phone, and I can swap in a newer Gemma or a fine-tune without changing the app.

## My First User

My first user is me. I ran the device test on my own iPhone with two months of my real runs: 22 runs, mostly 3 to 5 km, averaging about 14 km a week.

What it got right: it planned four easy runs and a slightly longer Sunday run, about the same volume I've been doing, at an easy pace close to how I actually run. No signals were flagged, and the note said so instead of inventing a problem.

What it taught me: the first estimate of my fitness was too low, because my "best" run wasn't an all-out effort. That's why the app now also estimates fitness from heart rate. And none of my runs since September 21 have heart rate recorded, so there's no drift to read and the coach is working with less than it could.

What I want next, as the user: an Apple Watch app that records runs with heart rate and shows the session's target pace and zone on the wrist. Then every run feeds the coach the data it needs.

I haven't put it in front of other runners yet. That's the next step, through TestFlight.

## Prize Categories

- **Best Use of Gemma**: Gemma 3 4B runs on the iPhone through MLX as the coach. Gemma 3 1B and Ollama-served Gemma are the fallbacks.
