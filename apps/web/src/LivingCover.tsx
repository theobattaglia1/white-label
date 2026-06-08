import { useEffect, useRef } from "react";

/* PLAYBACK v3 — living generative cover.
   Multi-mode generative field. Default (no props) = warm "Haze" drift, matching
   the home/song covers. Pass mode (0..5) / tone (0..3) / hue to drive the
   playlist cover pickers. Pure WebGL, one context per mount; falls back to
   nothing (transparent) when WebGL is unavailable — callers keep a CSS gradient
   behind it for that case.

   modes: 0 Flow · 1 Aurora · 2 Mesh · 3 Liquid · 4 Pulse · 5 Haze (default)
   tones: 0 Vivid · 1 Mono · 2 Pastel · 3 Custom-hue */

export const MOTION_MODES = [
  { id: 5, label: "Haze" },
  { id: 0, label: "Flow" },
  { id: 1, label: "Aurora" },
  { id: 2, label: "Mesh" },
  { id: 3, label: "Liquid" },
  { id: 4, label: "Pulse" },
] as const;
export const TONE_MODES = [
  { id: 0, label: "Vivid" },
  { id: 2, label: "Pastel" },
  { id: 1, label: "Mono" },
] as const;

const VERT = "attribute vec2 p;void main(){gl_Position=vec4(p,0.0,1.0);}";
const FRAG = [
  "precision highp float;uniform vec2 u_res;uniform float u_time;uniform int u_mode;uniform int u_tone;uniform vec3 u_hue;",
  "float hash(vec2 p){p=fract(p*vec2(123.34,456.21));p+=dot(p,p+45.32);return fract(p.x*p.y);}",
  "float noise(vec2 p){vec2 i=floor(p),f=fract(p);vec2 u=f*f*(3.0-2.0*f);float a=hash(i),b=hash(i+vec2(1.0,0.0)),c=hash(i+vec2(0.0,1.0)),d=hash(i+vec2(1.0,1.0));return mix(mix(a,b,u.x),mix(c,d,u.x),u.y);}",
  "float fbm(vec2 p){float v=0.0,a=0.5;for(int i=0;i<6;i++){v+=a*noise(p);p*=2.0;a*=0.5;}return v;}",
  "vec3 palette(float t,vec3 d){vec3 a=vec3(0.52,0.44,0.54),b=vec3(0.46,0.42,0.50),c=vec3(1.0,1.05,1.0);return a+b*cos(6.28318*(c*t+d));}",
  "vec3 hsv2rgb(vec3 c){vec3 r=clamp(abs(mod(c.x*6.0+vec3(0.0,4.0,2.0),6.0)-3.0)-1.0,0.0,1.0);return c.z*mix(vec3(1.0),r,c.y);}",
  "vec3 rgb2hsv(vec3 c){vec4 K=vec4(0.0,-0.3333333,0.6666667,-1.0);vec4 p=mix(vec4(c.bg,K.wz),vec4(c.gb,K.xy),step(c.b,c.g));vec4 q=mix(vec4(p.xyw,c.r),vec4(c.r,p.yzx),step(p.x,c.r));float d=q.x-min(q.w,q.y);float e=1.0e-10;return vec3(abs(q.z+(q.w-q.y)/(6.0*d+e)),d/(q.x+e),q.x);}",
  "void main(){vec2 uv=gl_FragCoord.xy/u_res.xy;float asp=u_res.x/u_res.y;vec2 p=vec2(uv.x*asp,uv.y)*1.7;",
  " float tForm=u_time*0.060,tCol=u_time*0.013;float f=0.5;vec3 dph=vec3(0.08,0.32,0.58);float extra=0.0;",
  " if(u_mode==0){vec2 q=vec2(fbm(p+tForm),fbm(p+vec2(5.2,1.3)-0.8*tForm));vec2 r=vec2(fbm(p+1.8*q+vec2(1.7,9.2)+0.15*tForm),fbm(p+1.8*q+vec2(8.3,2.8)-0.12*tForm));f=fbm(p+1.9*r);extra=0.12*length(q);}",
  " else if(u_mode==1){float warp=fbm(vec2(p.x*0.7,p.y*0.35)+vec2(0.0,tForm*1.2));f=fbm(vec2(p.x*1.4+warp*1.3,p.y*0.25-tForm*0.6));dph=vec3(0.0,0.22,0.5);extra=0.15*warp;}",
  " else if(u_mode==2){vec2 c1=vec2(0.5+0.40*sin(u_time*0.10),0.5+0.35*cos(u_time*0.08));vec2 c2=vec2(0.5+0.45*sin(u_time*0.07+2.0),0.5+0.40*cos(u_time*0.11+1.0));vec2 c3=vec2(0.5+0.38*sin(u_time*0.05+4.0),0.5+0.42*cos(u_time*0.09+3.0));float s=smoothstep(0.75,0.0,length(uv-c1))*0.55+smoothstep(0.75,0.0,length(uv-c2))*0.40-smoothstep(0.75,0.0,length(uv-c3))*0.30;f=0.5+0.7*s;dph=vec3(0.10,0.36,0.60);}",
  " else if(u_mode==3){vec2 q=vec2(fbm(p+0.5*tForm),fbm(p+vec2(3.0,2.0)-0.5*tForm));vec2 r=vec2(fbm(p+3.0*q+tForm),fbm(p+3.0*q+vec2(7.0,1.0)));float m=fbm(p+4.0*r);f=pow(clamp(abs(m-0.5)*2.0,0.0,1.0),0.7);dph=vec3(0.05,0.28,0.62);extra=0.10*length(r);}",
  " else if(u_mode==4){vec2 ctr=vec2(0.5*asp,0.5)*1.7;float d=length(p-ctr);f=fbm(p*0.8+0.3*tForm)+0.18*sin(d*6.0-u_time*1.2);dph=vec3(0.08,0.30,0.55);}",
  " else {float t2=u_time*0.052;vec2 sp=p*0.5;vec2 w=vec2(fbm(sp+vec2(0.0,t2)),fbm(sp+vec2(2.7,-0.9*t2)));float n2=fbm(sp+1.15*w+vec2(0.75*t2,0.18*t2));f=mix(uv.y*0.5+0.18,n2,0.76)+0.05*sin(u_time*0.22);dph=vec3(0.58,0.42,0.30);extra=0.05*w.x;}",
  " vec3 col=palette(f+tCol+extra,dph);float ff=clamp(f+extra,0.0,1.0);",
  " if(u_tone==1){float g=dot(col,vec3(0.299,0.587,0.114));col=clamp(vec3(0.5)+(vec3(g)-0.5)*1.18,0.0,1.0);}",
  " else if(u_tone==2){float l=dot(col,vec3(0.299,0.587,0.114));col=mix(vec3(l),col,0.5);col=mix(col,vec3(1.0),0.42);}",
  " else if(u_tone==3){vec3 h=rgb2hsv(u_hue);float val=0.26+0.74*ff;float sat=clamp(h.y*(1.2-0.55*ff),0.0,1.0);col=hsv2rgb(vec3(h.x+0.05*(ff-0.5),sat,val));}",
  " if(u_mode==5){float lz=dot(col,vec3(0.333));col=mix(col,vec3(lz),0.16);col*=0.82;}",
  " if(u_tone!=2 && u_mode!=5){col=mix(col,col*col*1.12,0.30);}",
  " float vig=smoothstep(1.35,0.20,length(uv-0.5));col*=0.74+0.26*vig;gl_FragColor=vec4(col,1.0);}",
].join("\n");

function compile(gl: WebGLRenderingContext, type: number, src: string) {
  const s = gl.createShader(type)!;
  gl.shaderSource(s, src);
  gl.compileShader(s);
  return s;
}

/* Per-artist / per-room world color — a curated palette picked by a stable
   hash of the seed, so each room/artist gets a consistent cover hue. */
const COVER_HUES = ["4663E8", "E14B6A", "E0A22E", "3AA6A0", "8A5BE6", "FF7A3C"];
function hexToRgb(hex: string): [number, number, number] {
  return [parseInt(hex.slice(0, 2), 16) / 255, parseInt(hex.slice(2, 4), 16) / 255, parseInt(hex.slice(4, 6), 16) / 255];
}
/** Distinct world color by position — guarantees adjacent cards never collide. */
export function hueAt(i: number): [number, number, number] {
  return hexToRgb(COVER_HUES[((i % COVER_HUES.length) + COVER_HUES.length) % COVER_HUES.length]);
}
export function coverHue(seed: string | undefined | null): [number, number, number] {
  const s = seed ?? "";
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  const hex = COVER_HUES[Math.abs(h) % COVER_HUES.length];
  return [parseInt(hex.slice(0, 2), 16) / 255, parseInt(hex.slice(2, 4), 16) / 255, parseInt(hex.slice(4, 6), 16) / 255];
}
/** Stable generative seed string for a given id — shown on the playlist cover. */
export function seedLabel(id: string | undefined | null): string {
  const s = id ?? "";
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return "0x" + (Math.abs(h) % 0xffff).toString(16).toUpperCase().padStart(4, "0");
}
export function hexToHue(hex: string): [number, number, number] {
  const h = hex.replace("#", "");
  return [parseInt(h.slice(0, 2), 16) / 255, parseInt(h.slice(2, 4), 16) / 255, parseInt(h.slice(4, 6), 16) / 255];
}

export function LivingCover({
  className = "",
  hue,
  mode,
  tone,
  style,
}: {
  className?: string;
  hue?: [number, number, number];
  mode?: number;
  tone?: number;
  style?: React.CSSProperties;
}) {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const gl = (canvas.getContext("webgl") ||
      canvas.getContext("experimental-webgl")) as WebGLRenderingContext | null;
    if (!gl) return;

    const prog = gl.createProgram()!;
    gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT));
    gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(prog);
    gl.useProgram(prog);

    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, "p");
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

    const uRes = gl.getUniformLocation(prog, "u_res");
    const uTime = gl.getUniformLocation(prog, "u_time");
    const uMode = gl.getUniformLocation(prog, "u_mode");
    const uTone = gl.getUniformLocation(prog, "u_tone");
    const uHue = gl.getUniformLocation(prog, "u_hue");

    const size = () => {
      const d = Math.min(2, window.devicePixelRatio || 1);
      const w = canvas.clientWidth || 300;
      const h = canvas.clientHeight || 300;
      canvas.width = Math.max(1, Math.floor(w * d));
      canvas.height = Math.max(1, Math.floor(h * d));
      gl.viewport(0, 0, canvas.width, canvas.height);
    };
    size();
    const ro = new ResizeObserver(size);
    ro.observe(canvas);

    // Defaults reproduce the original Haze cover: mode 5, and tone 3 (custom hue)
    // whenever a hue is supplied — exactly the home/song behavior.
    const renderMode = mode ?? 5;
    const renderTone = tone ?? (hue ? 3 : 0);
    const h = hue ?? [0.27, 0.39, 0.91];
    const start = performance.now();
    let raf = 0;
    const render = (now: number) => {
      gl.uniform2f(uRes, canvas.width, canvas.height);
      gl.uniform1f(uTime, (now - start) / 1000);
      gl.uniform1i(uMode, renderMode);
      gl.uniform1i(uTone, renderTone);
      gl.uniform3f(uHue, h[0], h[1], h[2]);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      raf = requestAnimationFrame(render);
    };
    raf = requestAnimationFrame(render);

    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
    };
  }, [hue ? hue.join(",") : "", mode ?? -1, tone ?? -1]);

  return <canvas ref={ref} className={className} style={style} aria-hidden="true" />;
}
