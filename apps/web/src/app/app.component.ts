import { Component, inject, AfterViewChecked } from '@angular/core';
import { CommonModule, DOCUMENT } from '@angular/common';
import { AuthService } from '@auth0/auth0-angular';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [CommonModule],
  templateUrl: './app.component.html',
})
export class AppComponent implements AfterViewChecked {
  private readonly auth = inject(AuthService);
  private readonly document = inject(DOCUMENT);

  readonly isAuthenticated$ = this.auth.isAuthenticated$;
  readonly user$ = this.auth.user$;

  private dashboardInitialized = false;
  private miniChartStart = 0;

  constructor() {
    // Reflect the auth state in the URL: /dashboard when signed in, / otherwise.
    this.isAuthenticated$.subscribe((authenticated) => {
      const path = authenticated ? '/dashboard' : '/';
      if (this.document.location.pathname !== path) {
        this.document.defaultView?.history.replaceState({}, '', path);
      }
      if (!authenticated) {
        this.dashboardInitialized = false;
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

  // Once the dashboard DOM is present, run the template's charts/widgets (ported
  // from docs/private/template/script.js) a single time.
  ngAfterViewChecked(): void {
    if (this.dashboardInitialized) return;
    if (!this.document.getElementById('bars-wrapper')) return;
    this.dashboardInitialized = true;
    const win = this.document.defaultView as any;
    win.requestAnimationFrame(() => this.renderMiniChart());
    this.renderBarChart();
    this.animateValues();
    this.initChatWidget();
  }

  private renderMiniChart(timestamp?: number): void {
    const canvas = this.document.getElementById('miniLineChart') as HTMLCanvasElement | null;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    const win = this.document.defaultView as any;

    if (!timestamp || typeof timestamp !== 'number') {
      this.miniChartStart = win.performance.now();
      win.requestAnimationFrame((t: number) => this.renderMiniChart(t));
      return;
    }

    const duration = 1200;
    const elapsed = timestamp - this.miniChartStart;
    const rawProgress = Math.min(elapsed / duration, 1);
    const progress = 1 - Math.pow(1 - rawProgress, 3);

    const rect = canvas.getBoundingClientRect();
    canvas.width = rect.width;
    canvas.height = rect.height;
    const w = canvas.width;
    const h = canvas.height;
    ctx.clearRect(0, 0, w, h);

    const data = [85, 88, 84, 85, 81, 79, 82, 77, 75, 78, 73, 70, 74, 75];
    const max = 100;
    const stepX = w / (data.length - 1);

    ctx.save();
    ctx.translate(0, h);
    ctx.scale(1, progress);
    ctx.translate(0, -h);

    ctx.beginPath();
    ctx.moveTo(0, h);
    data.forEach((val, i) => ctx.lineTo(i * stepX, h - (val / max) * h * 0.8 - 10));
    ctx.lineTo(w, h);
    ctx.closePath();
    const grad = ctx.createLinearGradient(0, 0, 0, h);
    grad.addColorStop(0, 'rgba(217, 4, 41, 0.4)');
    grad.addColorStop(1, 'rgba(217, 4, 41, 0)');
    ctx.fillStyle = grad;
    ctx.fill();

    ctx.beginPath();
    data.forEach((val, i) => {
      const x = i * stepX;
      const y = h - (val / max) * h * 0.8 - 10;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });
    ctx.strokeStyle = '#d90429';
    ctx.lineWidth = 2;
    ctx.lineJoin = 'round';
    ctx.stroke();
    ctx.restore();

    if (rawProgress < 1) {
      win.requestAnimationFrame((t: number) => this.renderMiniChart(t));
    }
  }

  private renderBarChart(): void {
    const barsWrapper = this.document.getElementById('bars-wrapper');
    if (!barsWrapper) return;
    const systemsData = [
      { p: 85, e: 10 }, { p: 35, e: 5 }, { p: 62, e: 12 },
      { p: 20, e: 8 }, { p: 75, e: 15 }, { p: 45, e: 7 },
      { p: 92, e: 4 }, { p: 30, e: 6 }, { p: 58, e: 18 },
    ];

    systemsData.forEach((sys, i) => {
      const item = this.document.createElement('div');
      item.className = 'bar-item';
      const track = this.document.createElement('div');
      track.className = 'bar-track';
      const purple = this.document.createElement('div');
      purple.className = 'bar-purple';
      purple.style.width = '0%';
      purple.style.backgroundColor = 'var(--blue)';
      const pink = this.document.createElement('div');
      pink.className = 'bar-pink';
      pink.style.width = '0%';
      pink.style.backgroundColor = 'var(--red)';
      track.appendChild(purple);
      track.appendChild(pink);
      item.appendChild(track);
      barsWrapper.appendChild(item);
      setTimeout(() => {
        purple.style.width = sys.p + '%';
        pink.style.width = sys.e + '%';
      }, 100 + i * 50);
    });
  }

  private animateValues(): void {
    const win = this.document.defaultView as any;
    const values = this.document.querySelectorAll('.value');
    values.forEach((node) => {
      const el = node as HTMLElement;
      const text = (el.innerText || '').trim();
      const numMatch = text.match(/[\d.]+/);
      if (!numMatch) return;
      const numStr = numMatch[0];
      const num = parseFloat(numStr.replace(/,/g, ''));
      const prefix = text.substring(0, text.indexOf(numStr));
      const suffix = text.substring(text.indexOf(numStr) + numStr.length);
      const duration = 1200;
      const startTime = win.performance.now();

      const update = (currentTime: number) => {
        const elapsed = currentTime - startTime;
        const progress = Math.min(elapsed / duration, 1);
        const eased = 1 - Math.pow(1 - progress, 3);
        const currentVal = num * eased;
        const displayVal = numStr.includes('.') ? currentVal.toFixed(1) : Math.floor(currentVal).toString();
        el.innerText = `${prefix}${displayVal}${suffix}`;
        if (progress < 1) win.requestAnimationFrame(update);
        else el.innerText = text;
      };
      setTimeout(() => win.requestAnimationFrame(update), 100);
    });
  }

  private initChatWidget(): void {
    const widget = this.document.getElementById('ai-chat-widget') as HTMLElement | null;
    if (!widget) return;
    const win = this.document.defaultView as any;
    let isDragging = false;
    let startX = 0;
    let startRight = 0;

    widget.addEventListener('pointerdown', (e: any) => {
      if (e.target.closest('div[onclick]') || e.target.closest('svg')) return;
      isDragging = true;
      startX = e.clientX;
      startRight = parseInt(win.getComputedStyle(widget).right, 10) || 40;
      widget.setPointerCapture(e.pointerId);
      widget.style.transition = 'none';
      widget.style.cursor = 'grabbing';
    });

    widget.addEventListener('pointermove', (e: any) => {
      if (!isDragging) return;
      const deltaX = e.clientX - startX;
      let newRight = startRight - deltaX;
      newRight = Math.max(0, Math.min(newRight, win.innerWidth - widget.offsetWidth));
      widget.style.right = newRight + 'px';
    });

    const stopDrag = (e: any) => {
      if (!isDragging) return;
      isDragging = false;
      widget.releasePointerCapture(e.pointerId);
      widget.style.transition = 'background-color 0.2s ease, border-color 0.2s';
      widget.style.cursor = 'grab';
    };
    widget.addEventListener('pointerup', stopDrag);
    widget.addEventListener('pointercancel', stopDrag);
  }
}
