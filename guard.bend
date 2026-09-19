import Base

# ==============================================================================
# The Path Guard
# ==============================================================================
# in_repo is the Bend port of path_is_in_repo (bendcoder_agent.c) — the check
# that keeps a self-editing agent inside its own repository. It lives in its
# own module so the agent loop (bendcoder_agent.bend, via edit_anchor.bend) can
# call the same guard the laws in LAWS.bend quantify over: the rules and the
# implementation cannot drift apart, because there is one implementation.
# ==============================================================================

# The head character may not lead a path out: '/' is absolute and '~' escapes
# through the shell's home expansion. path_is_in_repo checks path[0] for both.
def in_repo.head_ok(+h: Char) -> Bool:
  Bool.and(Bool.not(Char.is_eq(h, '/')), Bool.not(Char.is_eq(h, '~')))

# strstr(path, "..") as a scan: `dot` remembers whether the previous character
# was a '.', so a second one trips it. s leads the parameters because a
# self-call passes each argument unchanged until one shrinks — the flag
# behind it is free to move.
def in_repo.scan(s: String, dot: Bool) -> Bool:
  match s dot:
    case SNil{} _:
      False{}
    case SCon{h, t} False{}:
      in_repo.scan(t, Char.is_eq(h, '.'))
    case SCon{+h, t} True{}:
      Bool.or(Char.is_eq(h, '.'), in_repo.scan(t, Char.is_eq(h, '.')))

# The guard: an empty path names nothing, a '/' or '~' head leaves the repo,
# and ".." anywhere climbs out of it. Anything else is repo-relative.
def in_repo(p: String) -> Bool:
  match p:
    case SNil{}:
      False{}
    case SCon{+h, t}:
      Bool.and(in_repo.head_ok(h), Bool.not(in_repo.scan(SCon{h, t}, False{})))
