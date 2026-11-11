package app.aether.core

import app.aether.core.remote.PhoneLinkSession
import app.aether.core.remote.PhoneLinkSession.Access
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneLinkTest {
    private var clock = 1_000_000L
    private fun session() = PhoneLinkSession(now = { clock })

    @Test fun theFirstPhoneMustBeApprovedAndThenOnlyItIsServed() {
        val s = session()
        assertEquals(64, s.token.length)
        assertNotEquals(s.token, session().token)
        assertEquals(Access.NEEDS_APPROVAL, s.check(s.token, "192.168.1.5"))
        assertEquals(Access.WAITING, s.check(s.token, "192.168.1.5"))
        assertEquals(Access.DENIED, s.check(s.token, "192.168.1.9"))
        s.answer(true)
        assertEquals(Access.ALLOWED, s.check(s.token, "192.168.1.5"))
        assertEquals(Access.DENIED, s.check(s.token, "192.168.1.9"))
    }

    @Test fun aRefusedPhoneStaysOut() {
        val s = session()
        s.check(s.token, "10.0.0.2")
        s.answer(false)
        assertEquals(Access.DENIED, s.check(s.token, "10.0.0.2"))
        assertEquals(Access.NEEDS_APPROVAL, s.check(s.token, "10.0.0.3"))
    }

    @Test fun wrongTokensCloseTheSession() {
        val s = session()
        repeat(4) { assertEquals(Access.BAD_TOKEN, s.check("nope", "10.0.0.2")) }
        assertEquals(Access.BAD_TOKEN, s.check(null, "10.0.0.2"))
        assertEquals(Access.EXPIRED, s.check(s.token, "10.0.0.2"))
        assertTrue(s.isClosed)
    }

    @Test fun theSessionExpiresWhenIdleAndAfterItsMaximumLife() {
        val s = session()
        s.check(s.token, "a"); s.answer(true)
        clock += 9 * 60_000L
        assertEquals(Access.ALLOWED, s.check(s.token, "a"))
        clock += 9 * 60_000L
        assertEquals(Access.ALLOWED, s.check(s.token, "a"))
        clock += 11 * 60_000L
        assertEquals(Access.EXPIRED, s.check(s.token, "a"))
        val t = session()
        t.check(t.token, "a"); t.answer(true)
        repeat(4) { clock += 8 * 60_000L; t.check(t.token, "a") }
        assertTrue(t.isClosed)
    }
}
