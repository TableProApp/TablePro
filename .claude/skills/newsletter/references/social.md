# X posts

Write these from the finished newsletter, not from the changelog. The facts have already been
checked once and the editorial decisions have already been made, so starting again from the
changelog only creates a second version of the release that disagrees with the first.

Produce two things: a thread, and one standalone post for people who will not read a thread.

## The thread

One post per section of the newsletter, in the same order, plus a closing post. Six to eight
posts. Each post is the newsletter section compressed to its first idea and one supporting
fact, in the same voice: no first person, no em dash, no hype, numbers instead of adjectives.

Rules that differ from the email:

- **280 characters per post**, and a post that needs 279 of them is too dense. Aim for two
  short paragraphs with a blank line between.
- **No markdown.** X renders none of it. Backticks, bold and links in brackets all show as
  literal characters. Write `Cmd+Shift+O` as Cmd+Shift+O and `EXPLAIN ANALYZE` as EXPLAIN
  ANALYZE.
- **Links only in the last post.** A link in an early post costs reach and splits attention.
- **One image per post at most**, named in the post header so the person posting knows what to
  attach. Only images that exist and are current, same rule as the email.
- **The first post has to work alone**, because most people see only that one. Name the version
  and the single biggest change in the first two lines.

Format the output so it can be posted without editing:

```markdown
## 1/7 (attach: <image file, or omit>)

TablePro 0.66 is out.

<The headline change, two sentences.>

## 2/7

<Next section, compressed.>
```

Close the thread with the round-up in one post plus both links:

```
Also in 0.66: <three or four items, comma separated, no links>

Full changelog: https://docs.tablepro.app/changelog
Download: https://tablepro.app/download
```

## The standalone post

One post, no thread, for the same release. Version, then three or four changes in plain nouns,
then the download link. This is the version that gets reposted, so it has to survive with no
context around it.

```
TablePro 0.66 is out.

Query results from an aliased SELECT are editable again. Query Insights ranks your slowest and
most-run queries from local history. Open Quickly is rebuilt.

https://tablepro.app/download
```

## What not to do

No thread hooks ("a thread 🧵", "here's why this matters"), no engagement bait, no emoji as
decoration, no "and much more". The account posts release notes; the value is that they are
accurate and short. A post that reads like marketing is worse than no post, because the
audience is developers who can tell.
