import { Web3Storage } from 'web3.storage';

import validate from '../schemas/create-poll-body.js';
import type { Poll } from './types';

export interface Env {
  PINATA_JWT: string;
  WEB3_STORAGE_KEY: string;
  TURNSTILE_KEY?: string;
}

type Body = {
  poll: Poll;
  turnstile?: string;
};

class ApiError extends Error {
  constructor(public readonly status: number, error: any, public readonly details?: any) {
    super(error);
    Object.setPrototypeOf(this, ApiError.prototype);
  }
}

export const onRequestPost: PagesFunction<Env> = async (context) => {
  try {
    const { PINATA_JWT, WEB3_STORAGE_KEY, TURNSTILE_KEY } = context.env;
    const body = await parseBody(context.request);
    if (TURNSTILE_KEY) {
      if (!body.turnstile) throw new ApiError(400, 'missing turnstile key');
      const ip = context.request.headers.get('CF-Connecting-IP') ?? '';
      if (!(await checkTurnstile(TURNSTILE_KEY, ip, body.turnstile)))
        throw new ApiError(400, 'turnstile challenge failed');
    }
    const res = await pin(WEB3_STORAGE_KEY, PINATA_JWT, body.poll);
    return new Response(JSON.stringify(res), {
      status: 201,
      headers: { 'content-type': 'application/json' },
    });
  } catch (error) {
    const responseBody = JSON.stringify({ error: error.message, details: error.details });
    const status = error instanceof ApiError ? error.status : 500;
    return new Response(responseBody, { status, headers: { 'content-type': 'application/json' } });
  }
};

async function parseBody(req: Request): Promise<Body> {
  if (req.headers.get('content-type') !== 'application/json')
    throw new ApiError(400, 'input must be JSON');
  const reqBody = await req.json();
  if (!validate(reqBody)) {
    throw new ApiError(400, `Provided poll configuration was invalid`, validate.errors);
  }
  return reqBody as Body;
}

async function checkTurnstile(key: string, remoteIp: string, token: string): Promise<boolean> {
  const body = new FormData();
  body.append('secret', key);
  body.append('remoteip', remoteIp);
  body.append('response', token);
  const url = 'https://challenges.cloudflare.com/turnstile/v0/siteverify';
  const res = await fetch(url, { method: 'POST', body });
  const outcome: any = await res.json();
  if (outcome.success) return true;
  return false;
}

async function pin(
  web3StorageKey: string,
  pinataJwt: string,
  poll: Poll,
): Promise<{ ipfsHash: string }> {
  if (web3StorageKey) {
    console.log('posting to web3.storage');
    const client = new Web3Storage({ token: web3StorageKey });
    const file = new File([JSON.stringify(poll)], 'poll.json', { type: 'application/json' });
    const ipfsHash = await client.put([file]);
    return { ipfsHash };
  }
  const res = await fetch('https://api.pinata.cloud/pinning/pinJSONToIPFS', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${pinataJwt}`,
    },
    body: JSON.stringify({
      pinataContent: poll,
    }),
  });
  const resBody: any = await res.json();
  if (res.status !== 200) throw new ApiError(502, 'failed to pin', resBody.error ?? resBody);
  return { ipfsHash: resBody.IpfsHash };
}
