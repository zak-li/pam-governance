// PAM Governance frontend, single sign-on with auth0-spa-js v2.
// The user signs in through Auth0 and lands on the /dashboard success page.
// The UI exposes no direct access to Vault or Splunk, which are back-office
// infrastructure components.
const AUTH0_CONFIG = {
  domain: "dev-k5xncag6gzsmst88.eu.auth0.com",
  clientId: "WSLWksd8eYgpXPshHPEdMlaT84NKrGSL",
};

const DASHBOARD_PATH = "/dashboard";
let auth0Client = null;

window.onload = async () => {
  auth0Client = await auth0.createAuth0Client({
    domain: AUTH0_CONFIG.domain,
    clientId: AUTH0_CONFIG.clientId,
    authorizationParams: {
      redirect_uri: window.location.origin,
      scope: "openid profile email",
    },
    cacheLocation: "memory",
    useRefreshTokens: true,
  });

  // Complete the Auth0 redirect by exchanging the authorization code.
  const query = window.location.search;
  if (query.includes("state=") && (query.includes("code=") || query.includes("error="))) {
    try {
      await auth0Client.handleRedirectCallback();
    } catch (e) {
      console.error("Auth callback failed:", e);
    }
  }

  await render();
};

const render = async () => {
  const isAuthenticated = await auth0Client.isAuthenticated();
  const loginView = document.getElementById("logged-out-view");
  const dashboardView = document.getElementById("dashboard-view");

  if (isAuthenticated) {
    // Signed in, route to the /dashboard success page.
    if (window.location.pathname !== DASHBOARD_PATH) {
      window.history.replaceState({}, document.title, DASHBOARD_PATH);
    }
    loginView.classList.remove("active");
    loginView.classList.add("hidden");
    dashboardView.classList.remove("hidden");
    dashboardView.classList.add("active");

    const user = await auth0Client.getUser();
    document.getElementById("user-name").textContent = user.name || "User";
    document.getElementById("user-email").textContent = user.email || "";
    const avatar = document.getElementById("user-avatar");
    if (user.picture) avatar.src = user.picture;
  } else {
    // Signed out, always show the login page even when /dashboard is requested.
    if (window.location.pathname !== "/") {
      window.history.replaceState({}, document.title, "/");
    }
    dashboardView.classList.remove("active");
    dashboardView.classList.add("hidden");
    loginView.classList.remove("hidden");
    loginView.classList.add("active");
  }
};

document.getElementById("btn-login").addEventListener("click", async () => {
  await auth0Client.loginWithRedirect();
});

document.getElementById("btn-logout").addEventListener("click", async () => {
  // Federated logout clears the Auth0 session and the local cache.
  await auth0Client.logout({
    logoutParams: { returnTo: window.location.origin },
  });
});

// On back navigation or bfcache restore, re-evaluate the auth state. Together
// with Cache-Control no-store this prevents the dashboard from being shown
// after logout when the user clicks back.
window.addEventListener("pageshow", async (event) => {
  if (event.persisted) {
    if (auth0Client) {
      await render();
    } else {
      window.location.reload();
    }
  }
});
