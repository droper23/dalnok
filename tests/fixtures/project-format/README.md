# Project format fixtures (A-16)

One hand-written project per format version, 1 to 13, each using only the keys its version had
(`engine/api/project-format.json`) and exercising what that version added. Media paths point nowhere, so the clips
load offline; nothing here comes from a real project. `tests/engine/ProjectFormatTests.swift` loads each one,
saves it again and checks the feature survived.
