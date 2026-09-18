import Base
import ./LAWS.bend as Laws

# ==============================================================================
# The Path Guard, Proved
# ==============================================================================
# Each refusal law's quantified tail sits behind a concrete head — '/', '~',
# ".." or "" — and the guard's answer is decided before that tail is read, so
# both sides normalize to the same Bool and every proof is reflexivity {==}.
# allows_relative is a witness rather than a quantifier: the same check run
# on a concrete relative path.
# ==============================================================================

def Laws.Guard.no_absolute(p):
  {==}

def Laws.Guard.no_tilde(p):
  {==}

def Laws.Guard.no_parent(p):
  {==}

def Laws.Guard.no_empty():
  {==}

def Laws.Guard.allows_relative():
  {==}
