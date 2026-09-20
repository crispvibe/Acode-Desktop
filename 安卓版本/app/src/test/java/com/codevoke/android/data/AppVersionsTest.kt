package com.codevoke.android.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppVersionsTest {
    @Test
    fun compare_ignoresVPrefix() {
        assertEquals(0, AppVersions.compare("v1.2.3", "1.2.3"))
        assertEquals(0, AppVersions.compare("V0.4.0", "0.4.0"))
    }

    @Test
    fun compare_padsMissingSegments() {
        assertEquals(0, AppVersions.compare("1.0", "1.0.0"))
        assertEquals(0, AppVersions.compare("2", "2.0.0.0"))
    }

    @Test
    fun compare_numericSegmentsNotLexical() {
        assertTrue(AppVersions.compare("1.10.0", "1.9.9") > 0)
        assertTrue(AppVersions.compare("v0.4.0", "1.0") < 0)
    }

    @Test
    fun compare_prereleaseLowerThanRelease() {
        assertTrue(AppVersions.compare("1.0.0-beta", "1.0.0") < 0)
        assertTrue(AppVersions.compare("1.0.0", "1.0.0-beta") > 0)
        assertTrue(AppVersions.compare("1.0.0-alpha.1", "1.0.0-alpha") > 0)
        assertTrue(AppVersions.compare("1.0.0-alpha", "1.0.0-beta") < 0)
    }

    @Test
    fun compare_ignoresBuildMetadata() {
        assertEquals(0, AppVersions.compare("1.2.3+build.5", "1.2.3"))
    }

    @Test
    fun isNewer_onlyWhenStrictlyGreater() {
        assertTrue(AppVersions.isNewer("v0.4.1", "0.4.0"))
        assertFalse(AppVersions.isNewer("v0.4.0", "0.4.0"))
        assertFalse(AppVersions.isNewer("v0.3.9", "1.0"))
    }
}
