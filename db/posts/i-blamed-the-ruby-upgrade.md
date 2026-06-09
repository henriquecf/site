I bumped a large Rails app to Ruby 4.0.1, pushed the branch, and watched CI go red.

Five tests failed. Not the same five every time. I'd rerun the job and four of them would pass. Rerun again and a different one would fail. None of them ever failed on my laptop. They only failed on CI, and only sometimes.

That intermittence is its own special kind of frustration. A test that fails every time is a bug you can chase. A test that fails one run in three is a test that makes you doubt your own sanity before you doubt your code. You start clicking "re-run failed jobs" and treating green as the truth, because green is the answer you want.

And there was an obvious villain right at the top of the diff. I'd just changed the Ruby version. A major version bump is a big, scary, everything-touching change. When tests start failing the moment you make it, of course it's the upgrade. I spent the first hour reading the Ruby 4.0 release notes hunting for the thing that broke my tests.

The upgrade didn't break my tests. It just stopped letting them get away with being wrong.

## The failing tests all had the same shape

Once I stopped staring at the changelog and started reading the failures, a pattern showed up. Every failing test was a "prove this operation did nothing" assertion. Create a record, grab a timestamp off it, run some code that's supposed to leave that record alone, then assert the timestamp didn't move.

```ruby
test "does not change company_preference if filtered_search is already true" do
  cp = create_company_preference(company: @company, key: :config, value: { filtered_search: true })
  updated_at_before = cp.updated_at

  perform_job

  assert_equal updated_at_before, cp.reload.updated_at
end
```

The idea is sound. The job is supposed to skip this record, so `updated_at` shouldn't change. Capture it before, compare it after.

But look at what's on each side of that final comparison. On the left, `updated_at_before` is a Ruby `Time` object, the one Active Record put in memory when the row was created. On the right, `cp.reload.updated_at` is the same column read back out of Postgres. Those two values are supposed to be the same instant. Most of the time they are. Sometimes they're off by a few hundred nanoseconds, and `assert_equal` fails.

## Postgres rounds, Ruby doesn't

Ruby's `Time` can hold nanoseconds, nine digits after the decimal point. This is not new in Ruby 4.0. It's been true since Ruby 1.9. Postgres `timestamp` columns store microseconds, six digits. When Active Record writes a row, the in-memory object keeps whatever precision Ruby gave it. When you reload, Postgres hands back its own rounded, six-digit version of the same moment.

So `cp.updated_at` straight from memory carries nine digits, and `cp.reload.updated_at` carries six. They're the same instant at two different precisions. Ask `assert_equal` whether nine digits equals six and, roughly one percent of the time, the rounding has nudged the value and the answer is no.

This is a well-worn Rails gotcha with GitHub issues going back to Rails 4. I'd just never been bitten by it, and the reason I'd never been bitten is the whole point of the story.

## Why it failed on CI and never on my laptop

How often a timestamp carries sub-microsecond digits depends on the system clock. On Linux, the clock tends to hand out high-resolution times, so most timestamps have digits sitting past the microsecond mark, exactly the digits Postgres throws away on the round trip. On macOS, far fewer do.

My CI runs on Linux. I develop on a Mac. Same test, same code, same database engine, and the precision that trips the assertion shows up most of the time on one platform and rarely on the other. That is the entire reason it looked like the upgrade did it. The failures lived in CI, the upgrade ran in CI, and I had never once seen these tests fail anywhere else.

The Ruby bump was a coincidence of timing. A fresh base image, a clean dependency install, and a handful of CI runs that happened to land on the unlucky one percent. The biggest change in the diff caught the blame for a bug it had nothing to do with.

## The fix is one word

Reload before you capture.

```ruby
updated_at_before = cp.reload.updated_at
```

That's it. By reloading before reading `updated_at`, I snapshot the value Postgres actually stored instead of the higher-precision one Ruby happened to be holding in memory. Now both sides of the assertion come from the database, at the database's precision, and they match every single time.

Every failing precision test got the same edit. A timestamp captured from an in-memory object became a timestamp captured after a reload. The fix is boring. The afternoon it took to convince myself the upgrade wasn't responsible was not.

## The other flake, while I was in there

Auditing the time-sensitive tests turned up a second flake hiding in the same neighborhood, and it's a different bug worth knowing about.

A cron job flags "stuck" imports: anything still in `processing` after nine hours. The test set up records right at the boundary.

```ruby
started_at: 9.hours.ago.utc + 1.second   # not stuck, one second to spare
started_at: 9.hours.ago.utc - 1.second   # stuck, by one second
```

The records were created at setup time. The job computed its nine-hour cutoff later, at the moment it ran. On a fast, quiet machine that gap is nothing. On a loaded CI runner, enough real time passes between building the fixtures and running the job that a record sitting one second inside the boundary drifts to the wrong side of it. The "barely not stuck" record quietly becomes barely stuck, and the assertion flips.

The fix was to stop measuring from wall-clock-at-creation and anchor every record to one fixed reference time.

```ruby
started_at: @current_time - 9.hours + 1.second
```

Now every record's age is measured from the same instant, and that one-second margin doesn't evaporate while CI is busy doing something else.

Different bug, same family as the first one. Both tests trusted that a value read at one moment would still hold at another. Both were rock solid on a fast machine and flaky on a slow, busy one. Time in tests is treacherous in more than one way, and a slow CI box finds all of them. This is the same reason a [test suite that's green on your laptop](/blog/parallel-testing-elasticsearch-rails) can still surprise you the moment it runs somewhere else.

## What the upgrade was actually hiding

The fix took minutes. Finding it took the rest of the afternoon, and nearly all of that time went into suspecting the wrong thing.

The loudest change in the diff is a magnet for blame. A Ruby major version bump is exactly the kind of change your eye lands on first. It was sitting right there, it touched everything, and it had nothing to do with the actual bug. These tests had been wrong since the day they were written. They passed for years because I develop on a platform that happened to round in my favor, and CI rounded in my favor often enough that I never had a reason to look.

The upgrade didn't introduce the flake. It changed where the dice landed often enough that I finally had to.
