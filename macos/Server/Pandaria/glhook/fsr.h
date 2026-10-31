// FSR 1 in place of the client's final stretch blit; fsr.c.
// Upscales the read framebuffer's source rectangle into the draw framebuffer's destination one and
// returns 1, or returns 0 (nothing drawn) when it does not apply or its shaders failed.
int fsr_blit(int sx0, int sy0, int sx1, int sy1, int dx0, int dy0, int dx1, int dy1);
