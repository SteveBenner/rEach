# rEach Privacy Policy

rEach is the academic assistant for students in a course run on Teach. It is published by PatḗrasAI. This policy covers rEach and the "rEach" listing in the ChatGPT and Codex plugin directory, which only installs rEach.

## Who receives your information

rEach runs on your computer. It sends course information only to your course server: the Teach server your instructors run for your course. Your instructors control that server and what it keeps. PatḗrasAI runs no server that receives your course work or your conversations.

rEach downloads itself and its updates from its public GitHub repository, so GitHub sees those downloads like any other web request.

## What rEach sends to your course server

- Your enrollment details: the course passkey your instructor gave you, a security key rEach creates on your computer, and the rEach version, operating system and Ruby version.
- Your rEach password: when you enroll, when you choose a new one, and once more if this computer has not checked it before. Your course server keeps only a one-way scrambled form of it that cannot be turned back into the password, so nobody, your instructors included, can read or look it up. If you forget it, your instructor can allow you to choose a new one; that step is logged, without the password.
- Your submitted assignment files, and only when you say yes to submitting.
- Your answers to the questions in each assignment that only you can answer.
- Your assignment conversations. While you are signed in and working on an assignment in your course folder, rEach records what you type, your AI assistant's replies, reasoning and actions, what its tools and commands return to it, and the code it writes for the assignment, and sends them to your course server, where your instructors can read them. It records the whole text, however long, and sends it in the background while you work, about every ten minutes (your course sets how often), not only when you submit. Before anything is sent, rEach takes your identity out: the conversation travels and is stored under a random label instead of your name, and the identifiers rEach knows (your name, email, username, student ID, your computer account, home folder and computer name) are replaced in the text by placeholders such as `[[student-name]]`. The list that links the label and the placeholders back to you is encrypted on your computer so that only the holder of your course's key can open it. This is de-identification, not anonymity: your course server holds that key, so your instructors can reveal whose conversation it is, and each reveal is logged; your course server also knows which computer an upload came from while it receives it; and a name rEach does not know, such as a nickname or a teammate's name, stays in the text. A copy stays on your computer; ask rEach to export your conversations, or run `reach transcripts export`, to save it as a ZIP in your Downloads folder.
- When your AI assistant asks your instructors for help: a short summary with your recent changes.
- A scrambled fingerprint of your computer and computer account, never your files or passwords, so your course server can tell that your enrollment is used on the computer it was made on.
- Where you are in the course: the time you first passed each step of enrolling, first signed in, and first started each assignment. Only the step and its time, never anything you typed.
- Announcements: when an announcement from your instructors reached this computer and when rEach showed it to you. Only the times, never anything you typed.
- Which copy of the course materials this computer holds: the names and check values of the materials your course server sent, so your instructors can see that an update arrived. Never your own files.
- When rEach hits an error: a short report of where it happened, with no files, typed text or replies. While debug mode is on, these reports can include message text.

rEach also asks your course server whether anything changed (new course materials, grades, replies to your questions, receipts). It does this every few minutes while your AI assistant is open and about every 15 minutes in the background, even when no assistant is open. Each check sends only rEach's signed check from your computer: no files and nothing from your conversations. If the answer is that something changed, rEach then fetches it the same way `reach sync` does. To turn the background check off, set `subscribe.background` to `false` in rEach's `config.yml` or run `reach subscribe uninstall`. `REACH_SUBSCRIBE=0` turns off every check.

## What rEach does not send

- Conversations outside signed-in assignment work. Nothing said before you sign in, in your extracurricular folder or outside your course folder is recorded or sent.
- Other files on your computer, or anything outside your course folders.
- The files in your extracurricular folder.

## What stays on your computer

- A one-way scrambled check value for your rEach password, so rEach can check it when you sign in without sending it. The password itself is never stored, recorded in a conversation or shown to your AI assistant.
- Your profile: the answers you give rEach in its short interview. It is shared with your instructors only if you say yes when rEach asks them for help. Say "forget my profile" to delete it.
- What rEach learns about how you like to work, from what you type. Ask rEach "what do you know about me?" to see it, or ask it to forget.
- A copy of each submission, saved in your Downloads folder, and your submission receipts.

## Your AI provider

Like any chat, what you type to your AI assistant goes to the AI provider you use (for example OpenAI for Codex), under that provider's own privacy policy.

## Grades

Nothing rEach saves about you changes your grade. Your grade of record is kept by your school, not by rEach.

## Contact

For questions about this policy, open an issue at https://github.com/SteveBenner/rEach/issues. For questions about what your course server keeps, ask your instructors.
