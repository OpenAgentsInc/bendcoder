import Base

law typesafe.post:
  String -> IO(String)

def typesafe.post(payload):
  import "./typesafe_c.c"
  import "./typesafe_c.js"

def payload() -> String:
  "{\"state\":\"Help! My payouts have been failing for 3 days and I need this resolved urgently.\",\"model\":\"jev-latest\",\"questions\":{\"is_urgent\":{\"type\":\"noul\",\"instructions\":\"Does this message convey urgency or time-sensitivity?\"},\"department\":{\"type\":\"choice\",\"instructions\":\"Which department should handle this request?\",\"criteria\":{\"billing\":\"Payments, invoicing, refunds\",\"technical\":\"Bugs, outages, API errors\",\"sales\":\"Pricing, upgrades\"}}}}"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("Calling TypeSafe API from Bend via C...")
    resp : String <- typesafe.post(payload())
    IO.print("Response:")
    IO.print(resp)
