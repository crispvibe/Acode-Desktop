package com.codevoke.android.ui.state

import com.codevoke.android.data.RemoteChatAttachment
import com.codevoke.android.data.RemoteModel
import com.codevoke.android.data.RemoteProject
import com.codevoke.android.data.RemoteSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatUiStateTest {
    @Test
    fun filteredSessions_returnsOnlySelectedProjectSessions() {
        val state = ChatUiState(
            projects = listOf(
                RemoteProject(id = "project-a", name = "Project A", path = "/tmp/a"),
                RemoteProject(id = "project-b", name = "Project B", path = "/tmp/b"),
            ),
            sessions = listOf(
                session(id = "session-a", projectId = "project-a"),
                session(id = "session-b", projectId = "project-b"),
            ),
            selectedProjectId = "project-b",
        )

        assertEquals(listOf("session-b"), state.filteredSessions.map { it.id })
    }

    @Test
    fun selectedModelTitle_prefersMatchingModelTitle() {
        val state = ChatUiState(
            models = listOf(RemoteModel(id = "sonnet", title = "Claude Sonnet")),
            selectedModelId = "sonnet",
        )

        assertEquals("Claude Sonnet", state.selectedModelTitle)
    }

    @Test
    fun canSendDraft_acceptsAttachmentsWithoutText() {
        val state = ChatUiState(
            inputText = "",
            attachments = listOf(RemoteChatAttachment(filename = "capture.jpg", path = "/tmp/capture.jpg")),
        )

        assertTrue(state.canSendDraft)
    }

    private fun session(id: String, projectId: String?) = RemoteSession(
        id = id,
        cli = "claude",
        projectId = projectId,
        title = id,
        modelID = "sonnet",
        runStatus = "",
        statusText = "",
        queuedCount = 0,
    )
}
