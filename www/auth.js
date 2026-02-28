const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

function getSlackUserId(user) {
  if (user.user_metadata?.provider_id) return user.user_metadata.provider_id;
  const slack = user.identities?.find(i => i.provider === 'slack_oidc');
  if (slack?.identity_data?.provider_id) return slack.identity_data.provider_id;
  if (user.user_metadata?.sub) return user.user_metadata.sub;
  return user.id || user.email;
}

async function signInWithSlack() {
  const { data, error } = await sb.auth.signInWithOAuth({
    provider: 'slack_oidc',
    options: { redirectTo: window.location.href }
  });
  if (error) {
    const msg = document.getElementById('auth-msg');
    msg.classList.remove('hidden');
    msg.className = 'msg msg-error mt-2';
    msg.textContent = error.message;
  }
}

async function signOut() {
  await sb.auth.signOut();
  location.reload();
}

async function initAuth() {
  try {
    if (SUPABASE_ANON_KEY.includes('secret')) {
      showApp({ email: 'local-dev', id: 'local-dev' });
      return;
    }
    const { data: { session } } = await sb.auth.getSession();
    if (session) showApp(session.user);
    sb.auth.onAuthStateChange((_event, session) => {
      if (session) showApp(session.user);
    });
  } catch (e) {
    console.error('init error:', e);
  }
}

function esc(s) {
  if (s == null) return '';
  const d = document.createElement('div');
  d.textContent = String(s);
  return d.innerHTML;
}

function fmtState(s) {
  return (s || '').replace(/_/g, ' ');
}

function fmtDate(iso) {
  if (!iso) return '\u2014';
  return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function fmtEventType(t) {
  return (t || '').replace(/^ADR_/, '').replace(/_/g, ' ');
}
