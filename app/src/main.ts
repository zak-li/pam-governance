import { bootstrapApplication } from '@angular/platform-browser';
import { provideAuth0 } from '@auth0/auth0-angular';
import { AppComponent } from './app/app.component';

interface AppConfig {
  auth0Domain: string;
  auth0ClientId: string;
}

// Runtime config (assets/config.json) so the app is portable across Auth0
// tenants without rebuilding. deploy-app.sh regenerates it from Terraform.
fetch('assets/config.json')
  .then((response) => response.json())
  .then((config: AppConfig) =>
    bootstrapApplication(AppComponent, {
      providers: [
        provideAuth0({
          domain: config.auth0Domain,
          clientId: config.auth0ClientId,
          authorizationParams: {
            redirect_uri: window.location.origin,
            scope: 'openid profile email',
          },
          useRefreshTokens: true,
          cacheLocation: 'memory',
        }),
      ],
    }),
  )
  .catch((error) => console.error('Application bootstrap failed:', error));
