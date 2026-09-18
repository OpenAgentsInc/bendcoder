import Base
import ./agent_primitives.bend as P

# Checks the typed Classify answers against a response of the shape the API
# actually returns. The representation matters and is easy to get wrong: a
# one-field constructor whose field is a plain 32-bit value is packed into the
# term, while Missing's String needs a heap cell, so Nouled and Missing are
# built differently in json_parse_c.c despite looking alike in Bend.

def show_answer(a: P.Answer) -> String:
  match a:
    case P.Chosen{choice, confidence}:
      "Chosen(" ++ choice ++ ", " ++ F32.show(confidence) ++ ")"
    case P.Scored{score, confidence}:
      "Scored(" ++ F32.show(score) ++ ", " ++ F32.show(confidence) ++ ")"
    case P.Nouled{probability}:
      "Nouled(" ++ F32.show(probability) ++ ")"
    case P.Missing{reason}:
      "Missing"

def reply() -> String:
  "{\"model\":\"jev-1.13.0\",\"answers\":{"
    ++ "\"action\":{\"type\":\"choice\",\"choice\":\"run_build\",\"confidence\":0.67,\"probabilities\":{\"run_build\":0.78}},"
    ++ "\"has_enough_info\":{\"type\":\"noul\",\"noul\":0.1},"
    ++ "\"needs_code_change\":{\"type\":\"noul\",\"noul\":0.9},"
    ++ "\"confidence_score\":{\"type\":\"score\",\"score\":0.45,\"confidence\":0.33}}}"

def probe(+qid: String) -> IO(Unit):
  do IO<Unit>:
    a : P.Answer <- P.ParseAnswer(reply(), qid)
    IO.print(qid ++ " -> " ++ show_answer(a))

def main() -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- probe("action")
    u2 : Unit <- probe("has_enough_info")
    u3 : Unit <- probe("needs_code_change")
    u4 : Unit <- probe("confidence_score")
    probe("absent")

#|action -> Chosen(run_build, 0.67)
#|has_enough_info -> Nouled(0.1)
#|needs_code_change -> Nouled(0.9)
#|confidence_score -> Scored(0.45, 0.33)
#|absent -> Missing
