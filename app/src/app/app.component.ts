import { Component, inject } from '@angular/core';
import { CommonModule, DOCUMENT } from '@angular/common';
import { AuthService } from '@auth0/auth0-angular';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [CommonModule],
  templateUrl: './app.component.html',
})
export class AppComponent {
  private readonly auth = inject(AuthService);
  private readonly document = inject(DOCUMENT);

  readonly isAuthenticated$ = this.auth.isAuthenticated$;
  readonly user$ = this.auth.user$;

  constructor() {
    // Reflect the auth state in the URL: /dashboard when signed in, / otherwise.
    this.isAuthenticated$.subscribe((authenticated) => {
      const path = authenticated ? '/dashboard' : '/';
      if (this.document.location.pathname !== path) {
        this.document.defaultView?.history.replaceState({}, '', path);
      }
    });
  }

  login(): void {
    this.auth.loginWithRedirect();
  }

  logout(): void {
    this.auth.logout({
      logoutParams: { returnTo: this.document.location.origin },
    });
  }
}
