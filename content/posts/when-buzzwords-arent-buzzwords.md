---
title: "When 'Buzzwords' Reveal an Interview Leveling Mismatch"
date: 2026-01-15
draft: false
author: "Mark Gascoyne"
tags: ["interviews", "distributed-systems", "career", "system-design"]
categories: ["Engineering"]
---

I recently interviewed for a senior engineering role at a well-known fintech company. The interview went sideways in an interesting way, and the feedback I received reveals something important about how technical interviews can fail when leveling expectations aren't aligned.

## The Interview

The system design question was straightforward: **"Design a system that displays the top 5 songs currently being played in real-time across our streaming platform."**

I proposed a solution using:
- **Hash ring sharding** (by user_id to avoid hot partitions on popular songs)
- **State-based tracking** with 1-hour TTL (not time-windowed aggregation)
- **Gossip protocol** for service membership and discovery
- **Optimistic locking** for Redis cache updates to handle concurrent writes
- **HTTP Cache-Control headers** (max-age, stale-while-revalidate) for client-side caching
- **Redis caching layer** to prevent thundering herd problems and act as a circuit breaker

The design aimed for eventual consistency without requiring consensus protocols, with self-healing through TTL expiry and no single point of failure.

Here's the architecture flow:

```
Streaming Users (10M concurrent)
        ↓
Global Kafka Stream (playing/stopped events)
        ↓
    Hash Ring (shard by user_id)
        ↓
┌─────────┬─────────┬─────────┐
│ Shard 1 │ Shard 2 │ Shard 3 │  ← Each shard tracks songs
│ Users   │ Users   │ Users   │     for its user bucket
│ 1-33%   │ 34-66%  │ 67-100% │
└─────────┴─────────┴─────────┘
        ↑
   Gossip Protocol (Serf/Consul-style membership)
        ↓
Aggregation Service
    - Queries all shards: "Give me your top 5"
    - Merges results across shards
    - Calculates global top 5
        ↓
Redis Cache (optimistic locking via WATCH/MULTI/EXEC)
        ↓
GET /top-songs API
    Cache-Control: max-age=10, stale-while-revalidate=5
        ↓
    Clients (HTTP caching)
```

**Key design decisions:**
- **State-based tracking** (not time windows): Track who is currently playing what, with 1-hour TTL
- **Shard by user_id** (not song_id): Avoids hot partitions from viral songs
- **Gossip membership**: Automatic failure detection and self-healing
- **Optimistic locking**: Prevents race conditions on cache updates
- **Multi-layer caching**: Redis + HTTP + client-side


During the interview, I noticed the interviewer seemed surprised by several concepts. They asked clarifying questions about hash rings, seemed unfamiliar with optimistic locking patterns, and appeared genuinely interested when I mentioned HTTP caching strategies - as if this was new information rather than standard practice.

## The Feedback

A few days later, I received the rejection:

> "They reached a basic workable system design, although it was difficult to maintain shared understanding with the candidate. They repeatedly used buzzwords/terminology without stopping to check in with the interviewer to ensure they were following/understood."

Here's what stopped me: **Hash rings, gossip protocols, optimistic locking, and thundering herd aren't buzzwords.** They're fundamental distributed systems concepts that any senior engineer working on distributed systems should recognize, even if they don't use them daily.

These terms exist because they describe specific, well-understood technical problems and solutions:
- **Hash ring** = consistent hashing for distributed key-value storage
- **Gossip protocol** = decentralized membership and failure detection
- **Optimistic locking** = conflict resolution without blocking
- **Thundering herd** = cache stampede problem when many clients simultaneously request cold cache data

Using the correct terminology isn't "buzzwords" - it's being precise.

## The Real Problem: Leveling Mismatch

The feedback framed the interviewer's knowledge gaps as my communication failure. But here's the thing - I wasn't throwing around trendy terms to sound impressive. I was describing actual implementation patterns that would be necessary for the system they asked me to design.

Later, I learned the interviewer had 7 years at the company working on payment systems (BACS, Faster Payments, Mastercard integration). These are complex systems, but they hadn't worked with modern distributed systems architecture patterns. Kubernetes made them uncomfortable, and concepts like gossip protocols, hash rings, and optimistic locking weren't part of their domain experience.

**This wasn't a communication problem. It was a leveling problem.**

The company was hiring for a staff-level distributed systems role, but sent an engineer whose domain experience was in payment systems integration to evaluate distributed systems architecture. The interviewer couldn't distinguish between legitimate technical depth and "buzzwords" because they lacked the context to evaluate either.

## The "Ego" Red Flag

The feedback also mentioned:

> "Whilst the behavioural persuasion example was okay, they mentioned the main obstacle to others being persuaded of his point of view was their egos, which was a bit of a red flag."

The question was: "Tell me about a time you've convinced others about something technical. How did you approach it?"

I talked about introducing GitOps patterns (mono-repo, submodules) to teams that had been working in silos. My answer was:

"Most people are hesitant at first - it seems like a lot when you've been siloed for a long time. But I explain how it breaks down walls between departments because everyone can see and work on all the code. Even if you don't need to touch other team's code, it helps with communication and understanding. **99% of people love it once they see the benefits.** But there's always that 1% - the ones you couldn't convince to write unit tests or follow SOLID principles either. Usually it's ego - the 'rockstar developer' types who think best practices don't apply to them."

I was describing the **1% of engineers who resist all best practices**, not saying "everyone who disagreed with me had an ego problem."

But in an interview where the interviewer was already feeling technically out of their depth, that answer probably landed as: "This person thinks they're smarter than everyone else and dismisses people who don't agree."

Context matters. Even a reasonable answer can sound arrogant when the interviewer is already defensive.

## What I Learned

**1. Interview leveling matters both ways**

Companies need to ensure interviewers can actually evaluate the level they're hiring for. A mid-level engineer shouldn't be the primary technical evaluator for a staff-level distributed systems role - not because they're not smart, but because they literally can't distinguish signal from noise at that level.

**2. "Buzzwords" is sometimes code for "concepts I don't know"**

When feedback says you "used buzzwords," ask yourself: Were you actually using jargon unnecessarily, or were you using precise technical terminology that the interviewer wasn't familiar with? There's a meaningful difference.

**3. Calibrate to your audience - even in interviews**

I could have probed more during the interview: "Are you familiar with hash ring sharding? Let me explain how it works..." But that's a delicate dance - you don't want to sound condescending, and in a high-stakes interview, you're trying to demonstrate competence, not teach concepts.

**4. Word choice matters in behavioral questions**

Saying "their egos got in the way" is different from saying "there was initial resistance to changing direction, but once we did a proof-of-concept, everyone aligned." Same situation, drastically different framing.

## The Unexpected Twist

Oh, and there was one more thing: The recruiter also flagged that the interviewer was "95% confident I was drinking beer" during the 9am Tuesday video call.

I was drinking Robinsons summer fruits squash (pink liquid) in a Beavertown-branded pint glass that was a Christmas present.

I sent a polite clarification email immediately. The recruiter responded the following afternoon confirming HR had checked with the interviewer - it didn't affect the decision. I'd already failed on technical "communication" grounds (the "buzzwords" feedback).

But it's a useful reminder that video interview optics matter, even when you're just trying to stay hydrated with pink squash at 9am on a Tuesday.

## The Good Rejection

Here's the thing: **This was a good rejection for both of us.**

If their senior engineers don't regularly use distributed systems concepts like hash rings and gossip protocols, then my experience wouldn't have been valued there anyway. I would have been frustrated, they would have been frustrated, and we'd both be worse off.

The feedback about "buzzwords" told me everything I needed to know about the technical depth of the role and the team I'd be joining.

## For Other Candidates

If you get feedback that you "used too many buzzwords" or "didn't explain concepts clearly," consider:

1. **Were you actually using jargon unnecessarily?** Sometimes we do get carried away with terminology when simpler language would suffice.

2. **Or were you using precise technical language that the interviewer wasn't familiar with?** In which case, the leveling might not be right for that role.

3. **Did you probe for understanding during the interview?** I could have checked in more often with "Does that make sense?" or "Are you familiar with this pattern?"

4. **Is this a role where your depth would be valued?** If they're calling fundamental distributed systems concepts "buzzwords," they might not be working on the kinds of problems you want to solve.

## For Hiring Companies

If you're hiring for senior/staff level distributed systems roles:

1. **Ensure your interviewers can evaluate at that level.** Don't send someone who primarily works on monoliths to evaluate distributed systems expertise.

2. **Train interviewers to distinguish between buzzwords and technical depth.** "Eventual consistency" isn't a buzzword when you're literally designing an eventually-consistent system.

3. **Calibrate your leveling expectations.** If your team doesn't regularly use concepts like hash rings, CRDTs, or consensus protocols, you might not actually need staff-level distributed systems expertise - and that's fine! Just don't interview as if you do.

---

**Have you experienced interview leveling mismatches?** I'd love to hear your stories - both as a candidate and as an interviewer. What are the signs that an interviewer can't evaluate the level they're hiring for?

*Update: I'm currently exploring roles where distributed systems depth is actually valued. If you're working on interesting problems in this space, let's connect.*
