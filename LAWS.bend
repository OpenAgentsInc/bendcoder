import Base

# ==============================================================================
# The Path Guard, as Laws
# ==============================================================================
# in_repo is the Bend port of path_is_in_repo (bender_agent.c) — the check
# that keeps a self-editing agent inside its own repository. Where
# test_tools.c backs the C guard with five examples, each rule here is a law
# over every input, and PROOF.bend must fill each one or `bend PROOF.bend`
# fails the build the way a failing test does.
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

# ------------------------------------------------------------------------------
# The laws. Each holds over every input where the C version has one example.
# ------------------------------------------------------------------------------

# LAW: an absolute path is refused, whatever follows the leading '/'
law Guard.no_absolute:
  for p: String
  {in_repo(SCon{Chr{47}, p}) == False{} : Bool}

# LAW: a '~'-led path is refused, whatever follows it
law Guard.no_tilde:
  for p: String
  {in_repo(SCon{'~', p}) == False{} : Bool}

# LAW: a path climbing out through ".." is refused, whatever trails it
law Guard.no_parent:
  for p: String
  {in_repo(String.append("..", p)) == False{} : Bool}

# LAW: the empty path is refused
law Guard.no_empty:
  {in_repo("") == False{} : Bool}

# LAW: a plain relative path is allowed — without it the refusals above are
# equally satisfied by a guard that refuses everything
law Guard.allows_relative:
  {in_repo("sys_c.c") == True{} : Bool}
