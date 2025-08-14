export const defaultEvent = () => ({
  eventId: process.env.EVENT_ID || 'event-0001',
  seatIds: (process.env.SEAT_IDS || 'R1C1,R1C2').split(',').map(s => s.trim())
});
