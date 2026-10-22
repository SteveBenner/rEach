schema: teach.agent-control/v1
version: 3
tiers:
  - {id: wellbeing, rank: 1}
  - {id: control, rank: 2}
  - {id: rule, rank: 3}
  - {id: student, rank: 4}
  - {id: information, rank: 5}
  - {id: operational, rank: 6}
precedence:
  heading: "{{message:AC-PRECEDENCE-HEADING}}"
  lines:
    - "{{message:AC-PRECEDENCE-LINE-1}}"
    - "{{message:AC-PRECEDENCE-LINE-2}}"
    - "{{message:AC-PRECEDENCE-LINE-3}}"
    - "{{message:AC-PRECEDENCE-LINE-4}}"
    - "{{message:AC-PRECEDENCE-LINE-5}}"
frames:
  wellbeing:
    open: "{{message:AC-FRAME-WELLBEING-OPEN}}"
    close: "{{message:AC-FRAME-WELLBEING-CLOSE}}"
  control:
    open: "{{message:AC-FRAME-CONTROL-OPEN}}"
    close: "{{message:AC-FRAME-CONTROL-CLOSE}}"
  test:
    open: "{{message:AC-FRAME-TEST-OPEN}}"
    close: "{{message:AC-FRAME-TEST-CLOSE}}"
  rule:
    open: "{{message:AC-FRAME-RULE-OPEN}}"
    close: "{{message:AC-FRAME-RULE-CLOSE}}"
  student:
    open: "{{message:AC-FRAME-STUDENT-OPEN}}"
    close: "{{message:AC-FRAME-STUDENT-CLOSE}}"
  information:
    open: "{{message:AC-FRAME-INFORMATION-OPEN}}"
    close: "{{message:AC-FRAME-INFORMATION-CLOSE}}"
  announcement:
    open: "{{message:AC-FRAME-ANNOUNCEMENT-OPEN}}"
    close: "{{message:AC-FRAME-ANNOUNCEMENT-CLOSE}}"
  operational:
    open: "{{message:AC-FRAME-OPERATIONAL-OPEN}}"
    close: "{{message:AC-FRAME-OPERATIONAL-CLOSE}}"
channels:
  - {id: hello.persona, tier: rule, frame: rule, ceiling: rule}
  - {id: hello.session, tier: rule, frame: rule, ceiling: rule}
  - {id: hello.course_question, tier: rule, frame: rule, ceiling: rule}
  - {id: hello.greeting, tier: operational, frame: operational, ceiling: operational}
  - {id: hello.issues, tier: operational, frame: operational, ceiling: operational}
  - {id: hello.update, tier: operational, frame: operational, ceiling: operational}
  - {id: hello.profile, tier: student, frame: student, ceiling: student}
  - {id: hello.course, tier: operational, frame: operational, ceiling: operational}
  - {id: hello.modules, tier: operational, frame: operational, ceiling: operational}
  - {id: hello.module_move, tier: information, frame: information, ceiling: information}
  - {id: hello.late_work, tier: operational, frame: operational, ceiling: operational}
  - {id: hello.memory, tier: information, frame: information, ceiling: information}
  - {id: hello.storage, tier: operational, frame: operational, ceiling: operational}
  - {id: hello.locked, tier: operational, frame: operational, ceiling: operational}
  - {id: hello.hookless, tier: operational, frame: operational, ceiling: operational}
  - {id: hello.login, tier: operational, frame: operational, ceiling: operational}
  - {id: hello.refreshed, tier: operational, frame: operational, ceiling: operational}
  - {id: hello.controls, tier: control, frame: control, ceiling: control}
  - {id: hello.test, tier: control, frame: test, ceiling: control}
  - {id: rules.slice, tier: rule, frame: rule, ceiling: rule}
  - {id: rules.root, tier: rule, frame: rule, ceiling: rule}
  - {id: rules.extracurricular, tier: rule, frame: rule, ceiling: rule}
  - {id: rules.directives, tier: rule, frame: rule, ceiling: rule}
  - {id: gate.refusal, tier: operational, frame: operational, ceiling: operational}
  - {id: gate.login, tier: operational, frame: operational, ceiling: operational}
  - {id: gate.signin, tier: operational, frame: operational, ceiling: operational}
  - {id: gate.decision, tier: operational, frame: operational, ceiling: operational}
  - {id: gate.instructor, tier: operational, frame: operational, ceiling: operational}
  - {id: gate.control, tier: control, frame: control, ceiling: control}
  - {id: notice.update, tier: operational, frame: operational, ceiling: operational}
  - {id: notice.storage, tier: operational, frame: operational, ceiling: operational}
  - {id: notice.export_import, tier: operational, frame: operational, ceiling: operational}
  - {id: notice.debug, tier: operational, frame: operational, ceiling: operational}
  - {id: notice.late_work, tier: operational, frame: operational, ceiling: operational}
  - {id: notice.announcement, tier: information, frame: announcement, ceiling: information}
  - {id: notice.due_change, tier: information, frame: information, ceiling: information}
  - {id: notice.transcripts, tier: operational, frame: operational, ceiling: operational}
  - {id: notice.consent, tier: operational, frame: operational, ceiling: operational}
  - {id: notice.live, tier: information, frame: information, ceiling: information}
  - {id: notice.import, tier: operational, frame: operational, ceiling: operational}
  - {id: notice.next, tier: operational, frame: operational, ceiling: operational}
  - {id: notice.memory, tier: information, frame: information, ceiling: information}
  - {id: notice.subscribe, tier: operational, frame: operational, ceiling: operational}
  - {id: notice.control, tier: control, frame: control, ceiling: control}
  - {id: notice.test, tier: control, frame: test, ceiling: control}
  - {id: support.message, tier: wellbeing, frame: wellbeing, ceiling: wellbeing}
  - {id: mcp.relay, tier: operational, frame: operational, ceiling: operational}
  - {id: mcp.announcements, tier: information, frame: information, ceiling: information}
  - {id: mcp.control, tier: control, frame: control, ceiling: control}
  - {id: mcp.test, tier: control, frame: test, ceiling: control}
provenance:
  required: [control, test]
antifeatures:
  - {id: AF-ANNOUNCE-AS-RULE, rule: "{{message:AC-AF-ANNOUNCE-AS-RULE}}", enforced_by: frame, since: "rEach 0.37.0"}
  - {id: AF-STALE-TODAY, rule: "{{message:AC-AF-STALE-TODAY}}", enforced_by: frame, since: "rEach 0.37.0"}
  - {id: AF-SIGNIN-PROMISE, rule: "{{message:AC-AF-SIGNIN-PROMISE}}", enforced_by: catalogue, since: "rEach 0.33.1"}
  - {id: AF-SIGNIN-THROUGH-AI, rule: "{{message:AC-AF-SIGNIN-THROUGH-AI}}", enforced_by: gate, since: "rEach 0.16.0"}
  - {id: AF-WRITE-STUDENT-ANSWER, rule: "{{message:AC-AF-WRITE-STUDENT-ANSWER}}", enforced_by: "captured prompt", since: "rEach 0.20.0"}
  - {id: AF-BLAME-HOOKS, rule: "{{message:AC-AF-BLAME-HOOKS}}", enforced_by: catalogue, since: "rEach 0.28.1"}
  - {id: AF-SUPPORT-FIRST, rule: "{{message:AC-AF-SUPPORT-FIRST}}", enforced_by: gate, since: "rEach 0.12.0"}
  - {id: AF-CONTROL-LIFTED, rule: "{{message:AC-AF-CONTROL-LIFTED}}", enforced_by: controls, since: "rEach 0.37.0"}
  - {id: AF-INVENTED-LIMIT, rule: "{{message:AC-AF-INVENTED-LIMIT}}", enforced_by: frame, since: "rEach 0.37.0"}
  - {id: AF-TEST-ASSIST, rule: "{{message:AC-AF-TEST-ASSIST}}", enforced_by: test mode, since: "rEach 0.37.0"}
  - {id: AF-CONFIG-LIFTS-CONTROL, rule: "{{message:AC-AF-CONFIG-LIFTS-CONTROL}}", enforced_by: code, since: "rEach 0.39.0"}
  - {id: AF-UNSIGNED-CONTROL, rule: "{{message:AC-AF-UNSIGNED-CONTROL}}", enforced_by: provenance, since: "rEach 0.39.0"}
  - {id: AF-TIER-PROMOTION, rule: "{{message:AC-AF-TIER-PROMOTION}}", enforced_by: ceiling, since: "rEach 0.39.0"}
controls:
  kinds: [pause_course_work, hold_submissions, test]
  pause_course_work: {covers: [slice, root], spares: [extracurricular, support]}
  hold_submissions: {covers: [submit]}
  test:
    allowed_tools: [reach_test, reach_support, reach_status]
    agent_may: [{{message:AC-CONTROL-TEST-MAY}}]
    agent_never: [{{message:AC-CONTROL-TEST-NEVER}}]
