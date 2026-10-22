# AGENTS.md: reach

Reserved for an advanced agent persona built later. Until then this file holds only the directive rows below.

Asked to install rEach for a student? Follow INSTALL.md (directive INSTALL).

The course server is only what `reach` reports. `docs/`, `specs/` and `tools/` are developer material, never a source of an address or a port, and an agent never points rEach at localhost, 127.0.0.1 or a port on its own.

[ENVS] when developing this repo: it serves real users; dev is `main`, test is `test`, prod is `stable`; run `polispec resolve .` before writing and obey its verdict; table in .agents/directives/envs.md   d/ENVS   ⚙ guard:polispec   ⚡ [always]
[MICRODB] read `.agents/directives/microdatabase.md` for corpus backup and mirror work when this plugin owns a corpus; the copied directive is dormant until then   d/MICRODB   ⚙ none   ⚡ [task:corpus-backup, task:corpus-mirror]
[STUDENT1ST] audit every major feature against one principle: the student comes first; read `.agents/directives/student-first.md` before you design, build, or ship a major feature   d/STUDENT1ST   ⚙ none   ⚡ [task:feature-create, task:feature-change]
[INSTALL] install rEach for a student only through INSTALL.md; rplugin is optional   d/INSTALL   ⚙ none   ⚡ [task:install]
[RPLUGIN] reach is an rplugin plugin; sources, skills and release rules are in the full text   d/RPLUGIN   ⚙ none   ⚡ [task:feature-change, task:component-create, task:policy-change]
[CORPUS] read and write the corpus only through the plugin or rcorpus, never by editing files   d/CORPUS   ⚙ none   ⚡ [task:corpus-backup, task:corpus-mirror, task:corpus-change]
[COURSEMAT] no course material in this repository; reference blobs come only from Teach   d/COURSEMAT   ⚙ none   ⚡ [task:feature-change, task:course-material]
[KNOWNISSUE] known issues live in Teach, not in TODO.md; reach only reads them   d/KNOWNISSUE   ⚙ none   ⚡ [task:known-issue, task:feature-change]
[CHANGEIT] manifest, ports and zero-finding checks govern every change to reach   d/CHANGEIT   ⚙ none   ⚡ [task:feature-create, task:feature-change, task:component-create]

The full text of INSTALL, RPLUGIN, CORPUS, COURSEMAT, KNOWNISSUE and CHANGEIT is in `specs/polispec/surfaces/generated/repo-directives.md`; ENVS, MICRODB and STUDENT1ST are under `.agents/directives/`.

`CLAUDE.md` links to this file, so every harness reads the same text.
