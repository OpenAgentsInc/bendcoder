import Base
import ./guard.bend as G

# ==============================================================================
# The Path Guard, as Laws
# ==============================================================================
# in_repo is the Bend port of path_is_in_repo (bender_agent.c) — the check
# that keeps a self-editing agent inside its own repository. The def itself
# lives in guard.bend so the agent loop calls the same guard these laws
# quantify over. Where test_tools.c backs the C guard with five examples,
# each rule here is a law over every input, and PROOF.bend must fill each one
# or `bend PROOF.bend` fails the build the way a failing test does.
# ==============================================================================

# ------------------------------------------------------------------------------
# The laws. Each holds over every input where the C version has one example.
# ------------------------------------------------------------------------------

# LAW: an absolute path is refused, whatever follows the leading '/'
law Guard.no_absolute:
  for p: String
  {G.in_repo(SCon{Chr{47}, p}) == False{} : Bool}

# LAW: a '~'-led path is refused, whatever trails it
law Guard.no_tilde:
  for p: String
  {G.in_repo(SCon{'~', p}) == False{} : Bool}

# LAW: a path climbing out through ".." is refused, whatever trails it
law Guard.no_parent:
  for p: String
  {G.in_repo(String.append("..", p)) == False{} : Bool}

# LAW: the empty path is refused
law Guard.no_empty:
  {G.in_repo("") == False{} : Bool}

# LAW: a plain relative path is allowed — without it the refusals above are
# equally satisfied by a guard that refuses everything
law Guard.allows_relative:
  {G.in_repo("sys_c.c") == True{} : Bool}
