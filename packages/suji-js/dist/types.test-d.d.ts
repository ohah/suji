declare module "./index" {
    interface SujiHandlers {
        ping: {
            req: void;
            res: {
                msg: string;
            };
        };
        greet: {
            req: {
                name: string;
            };
            res: string;
        };
        add: {
            req: {
                a: number;
                b: number;
            };
            res: number;
        };
    }
}
export {};
