export type Poll = {
  creator: string;
  name: string;
  description: string;
  choices: string[];
  snapshot: string;
  termination: {
    conjunction: 'any' | 'all';
    quorum?: string;
    time?: number;
  };
  options: {
    publishVotes: boolean;
  };
};
