# OpenStride build plan

AI running coach for iOS. Reads Apple Health, computes your zones and load, builds a plan, and adapts it every week with an open-weight model (Gemma) running on the phone.

Deadline: DEV Hacktoberfest Week 2 ("Side Hustle"), Oct 18 2026.

## Principle

Math in code, judgment in the model. Zones, paces, load and the plan skeleton are deterministic. Gemma reviews the athlete state and picks adjustments from a fixed action set, with reasons. Guardrails clamp whatever it returns. If the model fails, a rule-based coach takes over, so the app never breaks.

## Architecture

```
HealthKit (iPhone) ──> HealthKitProvider ──> AthleteData
                                               │
                                     CoachKit (Swift package)
                     Metrics: HR zones (Karvonen), VDOT + pace zones,
                              TRIMP load, ACWR, weekly km, HR drift
                     PlanEngine: phases, weekly volume, session skeleton
                     CoachAgent: prompt -> LLM -> JSON -> guardrails
                                               │
                     LLMClient: MLX on-device (iPhone) | Ollama (Mac, simulator, eval)
```

## Milestones

1. CoachKit core: models, metrics, plan engine, unit tests
2. CoachAgent: prompt, JSON schema, guardrails, rule fallback, Ollama client
3. Eval harness (`coach-eval`): synthetic personas x models, scores validity, guardrail hits, expected direction, latency
4. iOS app: HealthKit read, onboarding, This Week, Insights, session detail, settings
5. On-device Gemma via MLX Swift
6. Run on iPhone with real Health data, screenshots, demo video
7. DEV post

## Eval personas

| Persona | Signal | Expected coach behavior |
|---|---|---|
| steady | consistent 25 km/wk, normal HR | progress, keep structure |
| overreaching | load spike, ACWR > 1.5 | cut volume, drop intensity |
| detrained | 3 weeks off | rebuild, easy only |
| hr_drift | high HR drift on easy runs | slow easy pace, more easy |
| missed_sessions | completed 1 of 4 last week | repeat week, no jump |
| beginner | 8 km/wk, short runs | small steps, run-walk friendly |
